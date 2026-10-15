import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

import app
import uvicorn

spec = importlib.util.spec_from_file_location(
    "hosted_smoke", Path(__file__).resolve().parents[1] / "scripts" / "test-hosted-agent.py"
)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)

ENDPOINT = "https://account.services.ai.azure.com/api/projects/project"
IMAGE = "registry/repo/agent@sha256:" + "a" * 64


def model_response():
    return {
        "status": "completed", "output_text": "JFrog supplies the Foundry image.",
        "metadata": {
            "execution_mode": "model", "model_deployment": "deployment",
            "upstream_response_id": "resp_upstream",
        },
    }


class ApplicationTests(unittest.TestCase):
    def setUp(self):
        self.config = patch.multiple(app, MODEL_DEPLOYMENT=None, PROJECT_ENDPOINT=None, _client=None)
        self.config.start()
        self.addCleanup(self.config.stop)
        self.client = TestClient(app.app)
        self.addCleanup(self.client.close)

    def test_echo_and_health(self):
        for path in ("/healthz", "/readiness", "/liveness"):
            self.assertEqual(self.client.get(path).json()["status"], "ok")
        response = self.client.post("/responses", json={"input": "Foundry image check"}).json()
        self.assertEqual(response["metadata"], {"execution_mode": "echo"})
        self.assertIn("Echo mode", response["output_text"])

    def test_blocked_and_capital_do_not_call_model(self):
        with patch.object(app, "get_model_client") as get_client:
            blocked = self.client.post("/responses", json={"input": "unrelated question"}).json()
            self.assertEqual(blocked["metadata"], {"execution_mode": "scope_blocked"})
            with patch.object(app, "CAPITALS", {"france": "Paris"}):
                capital = self.client.post("/responses", json={"input": "capital of France"}).json()
            self.assertEqual(capital["metadata"], {"execution_mode": "knowledge_lookup"})
            self.assertIn("Paris", capital["output_text"])
            get_client.assert_not_called()

    def test_model_provenance_and_array_input(self):
        client = Mock()
        client.responses.create.return_value = SimpleNamespace(
            status="completed", id="resp_upstream", output_text="Foundry answer"
        )
        with patch.object(app, "MODEL_DEPLOYMENT", "deployment"), patch.object(app, "get_model_client", return_value=client):
            response = self.client.post("/v1/responses", json={"input": [
                {"role": "user", "content": [{"type": "input_text", "text": "Foundry image check"}]}
            ]}).json()
            self.assertEqual(response["metadata"], model_response()["metadata"])
            self.assertEqual(client.responses.create.call_args.kwargs["input"], "Foundry image check")
            blocked = self.client.post("/responses", json={"input": "unrelated question"}).json()
            self.assertEqual(blocked["metadata"], {"execution_mode": "scope_blocked"})
            self.assertEqual(client.responses.create.call_count, 1)

    @patch.object(app, "MODEL_DEPLOYMENT", "deployment")
    def test_model_errors_are_failed_responses(self):
        client = Mock()
        for result in (SimpleNamespace(status="failed", id="r", output_text="text"),
                       SimpleNamespace(status="completed", id="", output_text="text"),
                       SimpleNamespace(status="completed", id="r", output_text="")):
            with self.subTest(result=result), patch.object(app, "get_model_client", return_value=client):
                client.responses.create.return_value = result
                response = self.client.post("/responses", json={"input": "Foundry check"}).json()
                self.assertEqual(response["status"], "failed")
                self.assertNotIn("metadata", response)
        client.responses.create.side_effect = RuntimeError("upstream unavailable")
        with patch.object(app, "get_model_client", return_value=client):
            self.assertEqual(self.client.post("/responses", json={"input": "Foundry check"}).json()["status"], "failed")

    def test_configured_model_requires_endpoint(self):
        with patch.object(app, "MODEL_DEPLOYMENT", "deployment"):
            response = self.client.post("/responses", json={"input": "Foundry check"}).json()
            self.assertEqual(response["status"], "failed")
            self.assertIn("FOUNDRY_PROJECT_ENDPOINT", response["error"]["message"])

    def test_streaming_keeps_model_provenance(self):
        client = Mock()
        client.responses.create.return_value = SimpleNamespace(
            status="completed", id="resp_upstream", output_text="Foundry answer"
        )
        with patch.object(app, "MODEL_DEPLOYMENT", "deployment"), patch.object(app, "get_model_client", return_value=client):
            response = self.client.post("/responses", json={"input": "Foundry check", "stream": True})
        events = [json.loads(line[6:]) for line in response.text.splitlines() if line.startswith("data: ")]
        self.assertEqual(events[0]["metadata"], model_response()["metadata"])
        self.assertEqual(events[-1]["response"]["metadata"], model_response()["metadata"])
        self.assertEqual(events[-1]["response"]["status"], "completed")

    def test_local_http_smoke_in_echo_and_mocked_model_modes(self):
        for model in (None, "deployment"):
            with self.subTest(model=model):
                client = Mock()
                client.responses.create.side_effect = lambda **kwargs: SimpleNamespace(
                    status="completed", id="resp_upstream",
                    output_text="ARRAYOK" if "ARRAYOK" in kwargs["input"] else "Foundry answer",
                )
                sock = socket.socket()
                sock.bind(("127.0.0.1", 0))
                base = f"http://127.0.0.1:{sock.getsockname()[1]}"
                server = uvicorn.Server(uvicorn.Config(app.app, log_level="error", access_log=False))
                thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]})
                with patch.object(app, "MODEL_DEPLOYMENT", model), patch.object(
                    app, "get_model_client", return_value=client if model else None
                ):
                    thread.start()
                    try:
                        deadline = time.monotonic() + 5
                        while time.monotonic() < deadline:
                            try:
                                with smoke.urllib.request.urlopen(f"{base}/readiness", timeout=0.5) as response:
                                    self.assertEqual(json.load(response)["status"], "ok")
                                break
                            except urllib.error.URLError:
                                time.sleep(0.02)
                        else:
                            self.fail("Owned local server never became responsive")
                        root = Path(__file__).resolve().parents[1]
                        commands = [[sys.executable, str(root / "test_local.py"), "--base", base]]
                        if shutil.which("pwsh"):
                            commands.append(["pwsh", "-NoProfile", "-File", str(root / "test-local.ps1")])
                        for command in commands:
                            result = subprocess.run(
                                command, env=dict(os.environ, BASE=base),
                                capture_output=True, text=True, timeout=30,
                            )
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    finally:
                        server.should_exit = True
                        thread.join(timeout=5)
                        sock.close()
                        self.assertFalse(thread.is_alive(), "Owned local server did not stop")


class SmokeTests(unittest.TestCase):
    def candidate(self, model="deployment"):
        return {"status": "active", "definition": {
            "container_configuration": {"image": IMAGE},
            "environment_variables": {"AZURE_AI_MODEL_DEPLOYMENT_NAME": model},
        }}

    def run_candidate(self, **kwargs):
        smoke.smoke_candidate(ENDPOINT, "agent", "42", self.candidate(), "token", 10, 1, **kwargs)

    def test_pinned_session_and_cleanup(self):
        with patch.object(smoke, "request_json", side_effect=[
            {"agent_session_id": "owned/session"}, {"status": "active"}, model_response(), {}
        ]) as request:
            self.run_candidate(expected_model="deployment")
        calls = request.call_args_list
        self.assertEqual(json.loads(calls[0].kwargs["data"])["version_indicator"],
                         {"type": "version_ref", "agent_version": "42"})
        self.assertIn("owned%2Fsession", calls[1].args[0])
        self.assertEqual(json.loads(calls[2].kwargs["data"])["agent_session_id"], "owned/session")
        self.assertEqual(calls[-1].kwargs["method"], "DELETE")
        self.assertEqual(calls[-1].args[0], calls[1].args[0])

    def test_echo_and_inferred_mode(self):
        response = {"status": "completed", "output_text": "echo", "metadata": {"execution_mode": "echo"}}
        with patch.object(smoke, "request_json", side_effect=[
            {"agent_session_id": "s"}, {"status": "active"}, response, {}
        ]):
            smoke.smoke_candidate(ENDPOINT, "agent", "42", self.candidate(""), "token", 10, 1)

    def test_model_mismatch_fails_before_creating_session(self):
        with patch.object(smoke, "request_json") as request, self.assertRaisesRegex(RuntimeError, "model mismatch"):
            self.run_candidate(expected_model="other")
        request.assert_not_called()

    def test_bad_execution_evidence_is_rejected_and_cleaned_up(self):
        responses = [
            {"status": "failed", "output_text": "error"},
            {"status": "completed", "output_text": " "},
            {"status": "completed", "output_text": "text"},
        ]
        for mode in ("scope_blocked", "echo", "knowledge_lookup"):
            response = model_response()
            response["metadata"]["execution_mode"] = mode
            responses.append(response)
        for key, value in (("model_deployment", "wrong"), ("upstream_response_id", ""), ("upstream_response_id", None)):
            response = model_response()
            response["metadata"][key] = value
            responses.append(response)
        for response in responses:
            with self.subTest(response=response), patch.object(smoke, "request_json", side_effect=[
                {"agent_session_id": "s"}, {"status": "active"}, response, {}
            ]) as request, self.assertRaises(RuntimeError):
                self.run_candidate()
            self.assertEqual(request.call_args.kwargs["method"], "DELETE")

    def test_session_creation_failure_never_invokes_default(self):
        for result in ({}, {"agent_session_id": ""}):
            with patch.object(smoke, "request_json", return_value=result) as request, self.assertRaisesRegex(RuntimeError, "no ID"):
                self.run_candidate()
            self.assertEqual(request.call_count, 1)
        with patch.object(smoke, "request_json", side_effect=urllib.error.URLError("create failed")) as request:
            with self.assertRaises(urllib.error.URLError):
                self.run_candidate()
            self.assertEqual(request.call_count, 1)

    def test_failed_session_is_cleaned_up(self):
        with patch.object(smoke, "request_json", side_effect=[
            {"agent_session_id": "s"}, {"status": "failed"}, {}
        ]) as request, self.assertRaisesRegex(RuntimeError, "unexpected status"):
            self.run_candidate()
        self.assertEqual(request.call_args.kwargs["method"], "DELETE")
        self.assertEqual(request.call_count, 3)

    def test_cleanup_failure_is_not_silent(self):
        with patch.object(smoke, "request_json", side_effect=[
            {"agent_session_id": "s"}, {"status": "active"}, model_response(), urllib.error.URLError("cleanup")
        ]), self.assertRaisesRegex(RuntimeError, "cleanup failed"):
            self.run_candidate()
        with patch.object(smoke, "request_json", side_effect=[
            {"agent_session_id": "s"}, {"status": "failed"}, urllib.error.URLError("cleanup")
        ]), patch.object(smoke, "sys", wraps=sys) as system, self.assertRaisesRegex(RuntimeError, "unexpected status"):
            self.run_candidate()
        system.stderr.write.assert_called()

    def test_exact_version_and_image_polling(self):
        with patch.object(smoke, "request_json", return_value=self.candidate()) as request:
            body = smoke.wait_until_active(ENDPOINT, "agent", "42", IMAGE, "token", 10, 1)
            self.assertEqual(body, self.candidate())
            self.assertIn("/versions/42?", request.call_args.args[0])
        with patch.object(smoke, "request_json", return_value=self.candidate()), self.assertRaisesRegex(RuntimeError, "image mismatch"):
            smoke.wait_until_active(ENDPOINT, "agent", "42", "wrong", "token", 10, 1)

    def test_polling_errors_retry_and_terminal_errors_fail(self):
        error = urllib.error.HTTPError(ENDPOINT, 503, "transient", {}, None)
        with patch.object(smoke, "request_json", side_effect=[error, self.candidate()]), patch.object(smoke.time, "sleep"):
            smoke.wait_until_active(ENDPOINT, "agent", "42", IMAGE, "token", 10, 1)
        for result in ({"status": "failed"}, {"status": "unknown"}):
            with patch.object(smoke, "request_json", return_value=result), self.assertRaises(RuntimeError):
                smoke.wait_until_active(ENDPOINT, "agent", "42", IMAGE, "token", 10, 1)
        error = urllib.error.HTTPError(ENDPOINT, 403, "forbidden", {}, None)
        with patch.object(smoke, "request_json", side_effect=error), self.assertRaisesRegex(RuntimeError, "403"):
            smoke.wait_until_active(ENDPOINT, "agent", "42", IMAGE, "token", 10, 1)

    def test_timeouts_and_session_retry(self):
        with patch.object(smoke.time, "monotonic", side_effect=[0, 11]), self.assertRaises(TimeoutError):
            smoke.wait_until_active(ENDPOINT, "agent", "42", IMAGE, "token", 10, 1)
        with patch.object(smoke.time, "monotonic", side_effect=[0, 11]), self.assertRaises(TimeoutError):
            smoke.wait_for_session("url", "token", 10, 1)
        with patch.object(smoke, "request_json", side_effect=[
            urllib.error.URLError("transient"), {"status": "creating"}, {"status": "active"}
        ]), patch.object(smoke.time, "sleep"):
            smoke.wait_for_session("url", "token", 10, 1)

    def test_empty_cleanup_response(self):
        response = Mock()
        response.read.return_value = b""
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        with patch.object(smoke.urllib.request, "urlopen", return_value=response):
            self.assertEqual(smoke.request_json(ENDPOINT, method="DELETE"), {})

    def test_token_override_and_oidc_exchange(self):
        with patch.dict(smoke.os.environ, {"AZURE_AI_ACCESS_TOKEN": "existing"}):
            self.assertEqual(smoke.get_access_token(), "existing")
        environment = {
            "ACTIONS_ID_TOKEN_REQUEST_URL": "https://github/token?x=1",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "request", "AZURE_TENANT_ID": "tenant",
            "AZURE_CLIENT_ID": "client",
        }
        with patch.dict(smoke.os.environ, environment, clear=True), patch.object(smoke, "request_json", side_effect=[
            {"value": "assertion"}, {"access_token": "access"}
        ]) as request:
            self.assertEqual(smoke.get_access_token(), "access")
            self.assertIn("&audience=", request.call_args_list[0].args[0])
            self.assertIn(b"client_assertion=assertion", request.call_args_list[1].kwargs["data"])

    def test_cli_wires_explicit_echo_model_and_inference(self):
        base_args = ["smoke", "--endpoint", ENDPOINT, "--agent", "agent", "--version", "42", "--expected-image", IMAGE]
        for model in ("", "deployment", None):
            args = base_args + (["--expected-model", model] if model is not None else [])
            with self.subTest(model=model), patch.object(sys, "argv", args), patch.object(
                smoke, "get_access_token", return_value="token"
            ), patch.object(smoke, "wait_until_active", return_value=self.candidate()), patch.object(
                smoke, "smoke_candidate"
            ) as invoke:
                self.assertEqual(smoke.main(), 0)
                self.assertEqual(invoke.call_args.args[-1], model)


if __name__ == "__main__":
    unittest.main()
