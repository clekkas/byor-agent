"""Wait for a Foundry hosted-agent version and invoke its Responses endpoint."""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

TRANSIENT_STATUS_CODES = {408, 429, 500, 502, 503, 504}


def required_environment(name):
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def request_json(url, *, headers=None, data=None, timeout=30, method=None):
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read()
        return json.loads(raw.decode("utf-8")) if raw else {}


def get_access_token():
    existing_token = os.getenv("AZURE_AI_ACCESS_TOKEN")
    if existing_token:
        return existing_token

    request_url = required_environment("ACTIONS_ID_TOKEN_REQUEST_URL")
    request_token = required_environment("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    separator = "&" if "?" in request_url else "?"
    oidc_response = request_json(
        f"{request_url}{separator}audience=api://AzureADTokenExchange",
        headers={"Authorization": f"Bearer {request_token}"},
    )
    assertion = oidc_response.get("value")
    if not assertion:
        raise RuntimeError("GitHub returned an empty OIDC token")

    tenant_id = required_environment("AZURE_TENANT_ID")
    client_id = required_environment("AZURE_CLIENT_ID")
    token_body = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "scope": "https://ai.azure.com/.default",
            "grant_type": "client_credentials",
            "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
            "client_assertion": assertion,
        }
    ).encode("ascii")
    token_response = request_json(
        f"https://login.microsoftonline.com/{urllib.parse.quote(tenant_id)}/oauth2/v2.0/token",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data=token_body,
    )
    access_token = token_response.get("access_token")
    if not access_token:
        raise RuntimeError("Microsoft Entra ID returned an empty access token")
    return access_token


def wait_until_active(endpoint, agent_name, version, expected_image, token, timeout, interval):
    agent_path = urllib.parse.quote(agent_name, safe="")
    version_path = urllib.parse.quote(version, safe="")
    url = (
        f"{endpoint.rstrip('/')}/agents/{agent_path}/versions/{version_path}"
        "?api-version=v1"
    )
    headers = {"Authorization": f"Bearer {token}"}
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        try:
            body = request_json(url, headers=headers)
        except urllib.error.HTTPError as error:
            if error.code not in TRANSIENT_STATUS_CODES:
                raise RuntimeError(f"Version lookup failed with HTTP {error.code}") from error
            print(f"Transient HTTP {error.code}; retrying.", flush=True)
        except (TimeoutError, urllib.error.URLError) as error:
            print(f"Transient status-request failure: {error}; retrying.", flush=True)
        else:
            status = body.get("status")
            if status == "active":
                image = (
                    body.get("definition", {})
                    .get("container_configuration", {})
                    .get("image")
                )
                if image != expected_image:
                    raise RuntimeError(
                        f"Active version image mismatch: expected {expected_image!r}, got {image!r}"
                    )
                print(f"Agent version {version} is active with the expected image.")
                return body
            if status in {"failed", "deleting", "deleted"}:
                raise RuntimeError(f"Agent version {version} entered terminal status {status!r}")
            if status != "creating":
                raise RuntimeError(f"Agent version {version} returned unknown status {status!r}")
            print(f"Agent version {version} is still creating.", flush=True)

        time.sleep(min(interval, max(0, deadline - time.monotonic())))

    raise TimeoutError(f"Timed out waiting for agent version {version} to become active")


def invoke(endpoint, agent_name, token, prompt, session_id, expected_model):
    agent_path = urllib.parse.quote(agent_name, safe="")
    url = (
        f"{endpoint.rstrip('/')}/agents/{agent_path}"
        "/endpoint/protocols/openai/responses?api-version=v1"
    )
    body = json.dumps({"input": prompt, "agent_session_id": session_id}).encode("utf-8")
    response = request_json(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        data=body,
        timeout=120,
    )
    if response.get("status") != "completed":
        raise RuntimeError(f"Smoke test returned status {response.get('status')!r}")
    output_text = response.get("output_text")
    if not isinstance(output_text, str) or not output_text.strip():
        raise RuntimeError("Smoke test returned no output_text")
    metadata = response.get("metadata")
    if not isinstance(metadata, dict):
        raise RuntimeError("Smoke test returned no execution provenance")
    expected_mode = "model" if expected_model else "echo"
    if metadata.get("execution_mode") != expected_mode:
        raise RuntimeError(f"Smoke test did not execute the expected {expected_mode} path")
    if expected_model:
        upstream_id = metadata.get("upstream_response_id")
        if metadata.get("model_deployment") != expected_model or not isinstance(upstream_id, str) or not upstream_id.strip():
            raise RuntimeError("Smoke test returned no evidence of the expected model call")
    print(f"Agent smoke test completed: {output_text[:200]}")


def session_url(endpoint, agent_name, session_id=None):
    url = f"{endpoint.rstrip('/')}/agents/{urllib.parse.quote(agent_name, safe='')}/endpoint/sessions"
    if session_id is not None:
        url += f"/{urllib.parse.quote(session_id, safe='')}"
    return f"{url}?api-version=v1"


def wait_for_session(url, token, timeout, interval):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            body = request_json(url, headers={"Authorization": f"Bearer {token}"})
        except urllib.error.HTTPError as error:
            if error.code not in TRANSIENT_STATUS_CODES:
                raise RuntimeError(f"Session lookup failed with HTTP {error.code}") from error
            print(f"Transient session HTTP {error.code}; retrying.", flush=True)
        except (TimeoutError, urllib.error.URLError) as error:
            print(f"Transient session-request failure: {error}; retrying.", flush=True)
        else:
            status = body.get("status")
            if status == "active":
                return
            if status != "creating":
                raise RuntimeError(f"Smoke session entered unexpected status {status!r}")
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
    raise TimeoutError("Timed out waiting for the candidate-pinned smoke session")


def smoke_candidate(endpoint, agent_name, version, version_info, token, timeout, interval, expected_model=None):
    configured_model = version_info.get("definition", {}).get("environment_variables", {}).get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "")
    if not isinstance(configured_model, str):
        raise RuntimeError("Candidate model deployment must be a string")
    if expected_model is None:
        expected_model = configured_model
    if configured_model != expected_model:
        raise RuntimeError(f"Candidate model mismatch: expected {expected_model!r}, got {configured_model!r}")
    session = request_json(
        session_url(endpoint, agent_name),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        data=json.dumps({"version_indicator": {"type": "version_ref", "agent_version": version}}).encode("utf-8"),
    )
    session_id = session.get("agent_session_id")
    if not isinstance(session_id, str) or not session_id.strip():
        raise RuntimeError("Foundry returned no ID for the candidate-pinned session")
    owned_url = session_url(endpoint, agent_name, session_id)
    try:
        wait_for_session(owned_url, token, timeout, interval)
        invoke(
            endpoint, agent_name, token,
            "For this Foundry deployment check, briefly describe the JFrog image pull connection.",
            session_id, expected_model,
        )
    finally:
        primary_failure = sys.exc_info()[0] is not None
        try:
            request_json(owned_url, headers={"Authorization": f"Bearer {token}"}, method="DELETE")
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            if not primary_failure:
                raise RuntimeError(f"Smoke session cleanup failed for {session_id}: {error}") from error
            print(f"Smoke session cleanup also failed for {session_id}: {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--agent", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--expected-image", required=True)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--expected-model", help="Expected model deployment; pass an empty string for echo, or omit to infer from the candidate")
    args = parser.parse_args()

    if args.timeout <= 0 or args.interval <= 0:
        parser.error("--timeout and --interval must be positive")

    token = get_access_token()
    version_info = wait_until_active(
        args.endpoint,
        args.agent,
        args.version,
        args.expected_image,
        token,
        args.timeout,
        args.interval,
    )
    smoke_candidate(
        args.endpoint,
        args.agent,
        args.version,
        version_info,
        token,
        args.timeout,
        args.interval,
        args.expected_model,
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"Hosted-agent validation failed: {error}", file=sys.stderr)
        sys.exit(1)
