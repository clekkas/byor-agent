import hashlib
import importlib.util
import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location(
    "registry_probe", Path(__file__).resolve().parents[1] / "scripts" / "test-registry-no-auth.py"
)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
IMAGE = f"{probe.REGISTRY}/{probe.REPOSITORY}@sha256:" + "a" * 64


class RegistryTests(unittest.TestCase):
    def test_image_and_definition_guards(self):
        self.assertEqual(probe.image_digest(IMAGE), "sha256:" + "a" * 64)
        for image in ("registry/repo:tag", IMAGE.replace("agent@", "other@"), IMAGE[:-1]):
            with self.assertRaises(ValueError):
                probe.image_digest(image)
        self.assertNotIn("registry_connection_id", probe.definition(IMAGE)["container_configuration"])
        self.assertEqual(probe.definition(IMAGE, probe.CONNECTION)["container_configuration"]["registry_connection_id"],
                         probe.CONNECTION)
        with self.assertRaises(ValueError):
            probe.definition(IMAGE, "other")

    def test_anonymous_challenge_never_uses_user_credentials(self):
        challenge = (f'Bearer realm="https://{probe.REGISTRY}/artifactory/api/docker/byor-demo-docker/v2/token",'
                     f'service="{probe.REGISTRY}",scope="repository:agent:pull"')
        with patch.object(probe, "http", side_effect=[
            (401, {"Www-Authenticate": challenge}, b""),
            (200, {}, b'{"token":"anonymous-token"}'),
            (403, {}, b""),
        ]) as http:
            self.assertEqual(probe.registry_get("manifests/sha256:x")[0], 403)
            self.assertNotIn("Authorization", http.call_args_list[0].kwargs["headers"])
            self.assertEqual(http.call_args_list[1].kwargs["headers"], {})
            self.assertEqual(http.call_args_list[2].kwargs["headers"]["Authorization"], "Bearer anonymous-token")

    def test_challenge_rejects_other_host_scope_and_insecure_realm(self):
        for realm, scope in [
            ("https://evil.example/token", "repository:agent:pull"),
            (f"http://{probe.REGISTRY}/token", "repository:agent:pull"),
            (f"https://{probe.REGISTRY}/token", "repository:other:pull"),
        ]:
            with patch.object(probe, "http", return_value=(
                401, {"WWW-Authenticate": f'Bearer realm="{realm}",scope="{scope}"'}, b""
            )):
                with self.assertRaises(RuntimeError):
                    probe.registry_get("manifests/sha256:x")

    def test_token_service_denial_and_invalid_token(self):
        challenge = f'Bearer realm="https://{probe.REGISTRY}/token",scope="repository:{probe.REPOSITORY}:pull"'
        with patch.object(probe, "http", side_effect=[
            (401, {"WWW-Authenticate": challenge}, b""), (403, {}, b"")
        ]):
            self.assertEqual(probe.registry_get("blobs/x")[0], 403)
        with patch.object(probe, "http", side_effect=[
            (401, {"WWW-Authenticate": challenge}, b""), (200, {}, b"{}")
        ]):
            with self.assertRaises(RuntimeError):
                probe.registry_get("blobs/x")

    def test_private_baseline_requires_denied_content_not_just_challenge(self):
        evidence = {"manifest": "m", "config": "c", "nonce_layer": "l"}
        for codes, expected in [
            ([401, 403, 401], "private_baseline_confirmed"),
            ([401, 403, 500], "inconclusive_registry_baseline"),
            ([200, 403, 401], "invalid_private_baseline"),
        ]:
            with patch.object(probe, "registry_get", side_effect=[(c, {}, b"content") for c in codes]), \
                    patch.object(probe, "check_digest"):
                self.assertEqual(probe.anonymous_baseline(evidence)[1], expected)

    def test_nonce_layer_is_downloaded_hashed_and_verified(self):
        nonce = "b" * 32
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            data = (nonce + "\n").encode()
            item = tarfile.TarInfo("app/probe-nonce.txt")
            item.size = len(data)
            archive.addfile(item, io.BytesIO(data))
        layer = stream.getvalue()
        layer_digest = "sha256:" + hashlib.sha256(layer).hexdigest()
        manifest = json.dumps({"config": {"digest": "sha256:" + "c" * 64},
                               "layers": [{"digest": layer_digest}]}).encode()
        digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
        image = f"{probe.REGISTRY}/{probe.REPOSITORY}@{digest}"
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"JFROG_USER": "u", "JFROG_TOKEN": "secret"}), \
                patch.object(probe, "registry_get", side_effect=[(200, {}, manifest), (200, {}, layer)]):
            path = Path(directory) / "image.json"
            probe.prepare(image, nonce, path)
            result = path.read_text()
            self.assertNotIn("secret", result)
            self.assertEqual(json.loads(result)["nonce_layer"], layer_digest)
        with self.assertRaises(RuntimeError):
            probe.check_digest(b"tampered", digest)

    def test_sanitized_errors_and_defaulted_config(self):
        self.assertEqual(probe.safe_diagnostic({
            "error": {"code": "Unauthorized", "message": "secret bearer token", "access_token": "secret"}
        }), {"error": {"code": "Unauthorized"}})
        result = probe.returned_definition({"definition": probe.definition(IMAGE, probe.CONNECTION)})
        self.assertTrue(result["connection_key_present"])
        self.assertEqual(result["registry_connection_id"], probe.CONNECTION)

    def test_classification_does_not_claim_anonymous_success(self):
        active = {"outcome": "active_smoke_passed"}
        self.assertEqual(probe.classify([active, active]), "omission_works_authentication_inconclusive")
        self.assertEqual(probe.classify([{"outcome": "api_rejected"}, active]), "omission_rejected_by_api")
        self.assertEqual(probe.classify([{"outcome": "timeout"}, active]), "omission_failed_review_registry_evidence")
        self.assertEqual(probe.classify([active, {"outcome": "deployment_failed"}]),
                         "inconclusive_positive_control_failed")
        denied = {"outcome": "deployment_failed", "failure_category": "registry_authorization"}
        self.assertEqual(probe.classify([denied, active]), "explicit_authentication_required_in_tested_configuration")


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        with patch.object(probe.smoke, "get_access_token", return_value="private-token"):
            self.experiment = probe.Experiment(Path(self.directory.name) / "ledger.json", timeout=1, interval=0.01)

    def test_ownership_and_production_guards(self):
        for name in ("private-registry-agent", "../other", "registry-probe-short"):
            with self.assertRaises(ValueError):
                self.experiment.path_for(name)
        with self.assertRaises(ValueError):
            self.experiment.cleanup("registry-probe-" + "a" * 32)

    def test_active_candidate_uses_exact_version_and_cleans_up(self):
        info = {"version": "1", "status": "active", "definition": probe.definition(IMAGE)}
        with patch.object(self.experiment, "api", side_effect=[
            (404, {}), (201, {"version": "1"}), (200, info), (202, {}), (404, {})
        ]) as api, patch.object(probe.smoke, "smoke_candidate") as smoke:
            result = self.experiment.attempt(IMAGE, None)
            self.assertEqual(result["outcome"], "active_smoke_passed")
            self.assertNotIn("registry_connection_id", api.call_args_list[1].args[2]["definition"]["container_configuration"])
            self.assertEqual(smoke.call_args.args[2], "1")
            self.assertEqual(smoke.call_args.args[-1], "")
            self.assertEqual(self.experiment.data["owned_agents"], [])
            self.assertNotIn("private-token", self.experiment.path.read_text())

    def test_partial_create_response_still_deletes_owned_agent(self):
        with patch.object(self.experiment, "api", side_effect=[
            (404, {}), TimeoutError(), (202, {}), (404, {})
        ]):
            result = self.experiment.attempt(IMAGE, None)
            self.assertEqual(result["outcome"], "experiment_error")
            self.assertEqual(self.experiment.data["owned_agents"], [])

    def test_api_rejection_and_failed_deployment_cleanup(self):
        for create, following, expected in [
            ((400, {"error": {"code": "InvalidRequest"}}), [], "api_rejected"),
            ((201, {"version": "1"}), [(200, {"status": "failed", "error": {
                "code": "ImagePullFailed", "message": "registry pull unauthorized"
            }})], "deployment_failed"),
        ]:
            with patch.object(self.experiment, "api", side_effect=[
                (404, {}), create, *following, (204, {}), (404, {})
            ]):
                self.assertEqual(self.experiment.attempt(IMAGE, None)["outcome"], expected)

    def test_cleanup_failure_is_explicit_and_retains_ledger(self):
        with patch.object(self.experiment, "api", side_effect=[
            (404, {}), (400, {}), (403, {})
        ]):
            with self.assertRaisesRegex(RuntimeError, "Cleanup DELETE failed"):
                self.experiment.attempt(IMAGE, None)
        self.assertEqual(len(self.experiment.data["owned_agents"]), 1)

    def test_collision_is_never_adopted(self):
        with patch.object(self.experiment, "api", return_value=(200, {})):
            with self.assertRaisesRegex(RuntimeError, "not confirmed absent"):
                self.experiment.attempt(IMAGE, None)
        self.assertEqual(self.experiment.data["owned_agents"], [])

    def test_retry_then_timeout_cleans_up(self):
        with patch.object(self.experiment, "api", side_effect=[
            (404, {}), (201, {"version": "1"}), (503, {}), (204, {}), (404, {})
        ]), patch.object(probe.time, "monotonic", side_effect=[0, 0, 2, 2, 2]), \
                patch.object(probe.time, "sleep"):
            self.assertEqual(self.experiment.attempt(IMAGE, None)["outcome"], "timeout")

    def test_smoke_failure_is_recorded_not_an_active_success(self):
        info = {"status": "active", "definition": probe.definition(IMAGE)}
        with patch.object(self.experiment, "api", side_effect=[
            (404, {}), (201, {"version": "1"}), (200, info), (204, {}), (404, {})
        ]), patch.object(probe.smoke, "smoke_candidate", side_effect=RuntimeError("smoke failed")):
            self.assertEqual(self.experiment.attempt(IMAGE, None)["outcome"], "experiment_error")

    def test_no_connection_always_precedes_control(self):
        evidence = {"image": IMAGE, "manifest": probe.image_digest(IMAGE),
                    "layers": ["sha256:" + "b" * 64], "nonce_layer": "sha256:" + "b" * 64}
        def attempt(image, connection):
            result = {"outcome": "active_smoke_passed", "connection": connection}
            self.experiment.data["attempts"].append(result)
            return result
        with patch.object(probe, "Experiment", return_value=self.experiment), \
                patch.object(self.experiment, "snapshot_production", return_value={"version": "20"}), \
                patch.object(probe, "anonymous_baseline", return_value=([], "private_baseline_confirmed")), \
                patch.object(self.experiment, "attempt", side_effect=attempt) as attempts:
            probe.run(IMAGE, evidence, self.experiment.path, 1)
            self.assertEqual([call.args[1] for call in attempts.call_args_list], [None, probe.CONNECTION])
            self.assertEqual(self.experiment.data["conclusion"], "omission_works_authentication_inconclusive")

    def test_invalid_baseline_never_creates_agents(self):
        evidence = {"image": IMAGE, "manifest": probe.image_digest(IMAGE),
                    "layers": ["sha256:" + "b" * 64], "nonce_layer": "sha256:" + "b" * 64}
        with patch.object(probe, "Experiment", return_value=self.experiment), \
                patch.object(self.experiment, "snapshot_production", return_value={"version": "20"}), \
                patch.object(probe, "anonymous_baseline", return_value=([], "invalid_private_baseline")), \
                patch.object(self.experiment, "attempt") as attempt:
            with self.assertRaisesRegex(RuntimeError, "cannot proceed"):
                probe.run(IMAGE, evidence, self.experiment.path, 1)
            attempt.assert_not_called()

    def test_failed_positive_control_is_not_a_successful_run(self):
        evidence = {"image": IMAGE, "manifest": probe.image_digest(IMAGE),
                    "layers": ["sha256:" + "b" * 64], "nonce_layer": "sha256:" + "b" * 64}
        def attempt(image, connection):
            self.experiment.data["attempts"].append({"outcome": "deployment_failed"})
        with patch.object(probe, "Experiment", return_value=self.experiment), \
                patch.object(self.experiment, "snapshot_production", return_value={"version": "20"}), \
                patch.object(probe, "anonymous_baseline", return_value=([], "private_baseline_confirmed")), \
                patch.object(self.experiment, "attempt", side_effect=attempt):
            with self.assertRaisesRegex(RuntimeError, "positive control"):
                probe.run(IMAGE, evidence, self.experiment.path, 1)


if __name__ == "__main__":
    unittest.main()
