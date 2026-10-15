"""Isolated, manual private-registry experiment. Never targets production agents."""

import argparse
import base64
import hashlib
import importlib.util
import io
import json
import os
import re
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

ENDPOINT = "https://kaiser-foundry-resource.services.ai.azure.com/api/projects/workshop-demo-project"
REGISTRY = "trialndswdc.jfrog.io"
REPOSITORY = "byor-demo-docker/agent"
CONNECTION = "jfrog-registry-acct"
PREFIX = "registry-probe-"
PRODUCTION = "private-registry-agent"
DIGEST = re.compile(r"sha256:[0-9a-f]{64}\Z")
TRANSIENT = {408, 429, 500, 502, 503, 504}
MANIFEST_TYPES = "application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.manifest.v1+json"

spec = importlib.util.spec_from_file_location(
    "registry_smoke", Path(__file__).with_name("test-hosted-agent.py")
)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def http(url, *, headers=None, body=None, method="GET", redirects=0):
    """Never forward Authorization to blob-storage redirects or print signed URLs."""
    request = urllib.request.Request(url, headers=headers or {}, data=body, method=method)
    try:
        response = urllib.request.build_opener(NoRedirect()).open(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        status, response_headers = response.code, dict(response.headers.items())
        raw = response.read()
    location = next((v for k, v in response_headers.items() if k.lower() == "location"), None)
    if status in {301, 302, 303, 307, 308} and location:
        target = urllib.parse.urljoin(url, location)
        parsed = urllib.parse.urlsplit(target)
        if redirects >= 3 or parsed.scheme != "https" or parsed.username or parsed.password:
            raise RuntimeError("Unsafe or excessive registry redirect")
        # Only content GETs can redirect. Azure mutations must never be replayed elsewhere.
        if method != "GET" or "/v2/" not in urllib.parse.urlsplit(url).path:
            raise RuntimeError("Unexpected API redirect")
        safe_headers = {k: v for k, v in (headers or {}).items() if k.lower() != "authorization"}
        return http(target, headers=safe_headers, redirects=redirects + 1)
    return status, response_headers, raw


def registry_get(path, credential=None):
    url = f"https://{REGISTRY}/v2/{REPOSITORY}/{path}"
    headers = {"Accept": MANIFEST_TYPES}
    if credential:
        headers["Authorization"] = credential
    status, response_headers, raw = http(url, headers=headers)
    challenge = next((v for k, v in response_headers.items() if k.lower() == "www-authenticate"), "")
    if status != 401 or not challenge.lower().startswith("bearer "):
        return status, response_headers, raw
    fields = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
    realm = urllib.parse.urlsplit(fields.get("realm", ""))
    if realm.scheme != "https" or realm.netloc != REGISTRY or realm.username:
        raise RuntimeError("Bearer challenge points outside the approved registry")
    scope = fields.get("scope", "")
    # Artifactory uses a repo-specific token endpoint and image-relative scope.
    allowed_scopes = {f"repository:{REPOSITORY}:pull"}
    if realm.path == "/artifactory/api/docker/byor-demo-docker/v2/token":
        allowed_scopes.add("repository:agent:pull")
    if scope not in allowed_scopes:
        raise RuntimeError("Bearer challenge has an unexpected repository scope")
    query = urllib.parse.parse_qsl(realm.query) + [
        ("service", fields.get("service", "")), ("scope", scope)
    ]
    token_url = urllib.parse.urlunsplit(realm._replace(query=urllib.parse.urlencode(query)))
    token_headers = {"Authorization": credential} if credential else {}
    token_status, _, token_raw = http(token_url, headers=token_headers)
    if token_status != 200:
        return token_status, {}, b""
    token_body = json.loads(token_raw)
    token = token_body.get("token") or token_body.get("access_token")
    if not isinstance(token, str) or not token:
        raise RuntimeError("Registry token service returned no bearer token")
    return http(url, headers={"Accept": MANIFEST_TYPES, "Authorization": f"Bearer {token}"})


def image_digest(image):
    prefix = f"{REGISTRY}/{REPOSITORY}@"
    if not image.startswith(prefix) or not DIGEST.fullmatch(image[len(prefix):]):
        raise ValueError("Experiment image must be a digest in the approved BYOR repository")
    return image[len(prefix):]


def check_digest(raw, expected):
    if "sha256:" + hashlib.sha256(raw).hexdigest() != expected:
        raise RuntimeError("Downloaded registry content failed its digest check")


def prepare(image, nonce, evidence):
    digest = image_digest(image)
    username, token = os.environ["JFROG_USER"], os.environ["JFROG_TOKEN"]
    basic = base64.b64encode(f"{username}:{token}".encode()).decode()
    credential = f"Basic {basic}"
    status, _, raw = registry_get(f"manifests/{digest}", credential)
    if status != 200:
        raise RuntimeError(f"Authenticated manifest read failed: HTTP {status}")
    check_digest(raw, digest)
    manifest = json.loads(raw)
    config = manifest["config"]["digest"]
    layers = [layer["digest"] for layer in manifest["layers"]]
    if not DIGEST.fullmatch(config) or not layers or not all(DIGEST.fullmatch(d) for d in layers):
        raise RuntimeError("Image has invalid manifest digests")
    layer = layers[-1]
    status, _, raw = registry_get(f"blobs/{layer}", credential)
    if status != 200:
        raise RuntimeError(f"Authenticated nonce-layer read failed: HTTP {status}")
    check_digest(raw, layer)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:*") as archive:
        member = archive.extractfile("app/probe-nonce.txt")
        if member is None or member.read().decode().strip() != nonce:
            raise RuntimeError("Final image layer does not contain this experiment's nonce")
    save(evidence, {
        "image": image, "manifest": digest, "config": config, "layers": layers,
        "nonce_layer": layer, "nonce": nonce, "prepared_at": timestamp(),
        "source_revision": os.getenv("GITHUB_SHA"), "run_id": os.getenv("GITHUB_RUN_ID"),
    })


def anonymous_baseline(evidence):
    results = []
    for kind, digest in (("manifests", evidence["manifest"]), ("blobs", evidence["config"]),
                         ("blobs", evidence["nonce_layer"])):
        status, _, raw = registry_get(f"{kind}/{digest}")
        if status == 200:
            check_digest(raw, digest)
        results.append({"kind": kind, "digest": digest, "status": status})
    if any(r["status"] == 200 for r in results):
        return results, "invalid_private_baseline"
    if not all(r["status"] in {401, 403} for r in results):
        return results, "inconclusive_registry_baseline"
    return results, "private_baseline_confirmed"


def definition(image, connection=None):
    container = {"image": image}
    if connection is not None:
        if connection != CONNECTION:
            raise ValueError("Unexpected registry connection")
        container["registry_connection_id"] = connection
    return {
        "kind": "hosted", "cpu": "0.5", "memory": "1Gi",
        "container_configuration": container,
        "environment_variables": {"AZURE_AI_MODEL_DEPLOYMENT_NAME": ""},
        "protocol_versions": [{"protocol": "responses", "version": "2.0.0"}],
    }


def safe_diagnostic(value):
    """Keep useful failure codes without persisting potentially credential-bearing messages."""
    if isinstance(value, dict):
        return {k: safe_diagnostic(v) for k, v in value.items()
                if k in {"code", "type", "status", "error", "innererror", "details"}}
    if isinstance(value, list):
        return [safe_diagnostic(v) for v in value[:10]]
    if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,100}", value):
        return value
    return None


def returned_definition(body):
    result = body.get("definition", {})
    container = result.get("container_configuration", {})
    return {
        "image": container.get("image"),
        "registry_connection_id": container.get("registry_connection_id"),
        "connection_key_present": "registry_connection_id" in container,
        "cpu": result.get("cpu"), "memory": result.get("memory"),
    }


def failure_category(error):
    text = json.dumps(error).lower()
    if any(word in text for word in ("registry", "image", "pull")) and any(
        word in text for word in ("unauthorized", "authentication", "access denied", "401", "403")
    ):
        return "registry_authorization"
    return "unclassified"


class Experiment:
    def __init__(self, ledger, timeout=1800, interval=10):
        self.path = Path(ledger)
        self.timeout, self.interval = timeout, interval
        self.token = smoke.get_access_token()
        self.data = {"started_at": timestamp(), "endpoint": ENDPOINT, "owned_agents": [], "attempts": []}

    def persist(self):
        save(self.path, self.data)

    def api(self, path, method="GET", body=None):
        url = f"{ENDPOINT}{path}?api-version=v1"
        raw_body = json.dumps(body).encode() if body is not None else None
        status, _, raw = http(url, method=method, body=raw_body, headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/json"
        })
        result = json.loads(raw) if raw else {}
        return status, result

    def path_for(self, name):
        if not re.fullmatch(r"registry-probe-[a-z0-9-]{8,60}", name):
            raise ValueError("Cleanup refuses a name outside the experiment namespace")
        return f"/agents/{name}"

    def snapshot_production(self):
        status, body = self.api(f"/agents/{PRODUCTION}")
        if status != 200:
            raise RuntimeError(f"Production metadata lookup failed: HTTP {status}")
        latest = body["versions"]["latest"]
        return {"version": latest["version"], "definition": returned_definition(latest)}

    def cleanup(self, name):
        path = self.path_for(name)
        if name not in self.data["owned_agents"]:
            raise ValueError("Cleanup refuses an unowned agent")
        status, _ = self.api(path, "DELETE")
        if status not in {200, 202, 204, 404}:
            raise RuntimeError(f"Cleanup DELETE failed for {name}: HTTP {status}")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            status, _ = self.api(path)
            if status == 404:
                self.data["owned_agents"].remove(name)
                self.persist()
                return
            if status not in {200, 202} | TRANSIENT:
                raise RuntimeError(f"Cleanup verification failed for {name}: HTTP {status}")
            time.sleep(min(self.interval, max(0, deadline - time.monotonic())))
        raise RuntimeError(f"Cleanup timed out for {name}")

    def attempt(self, image, connection):
        name = PREFIX + uuid.uuid4().hex + ("-control" if connection else "-omitted")
        path = self.path_for(name)
        status, _ = self.api(path)
        if status != 404:
            raise RuntimeError(f"Temporary name is not confirmed absent: HTTP {status}")
        attempt = {"name": name, "started_at": timestamp(), "connection": connection,
                   "submitted_definition": definition(image, connection), "history": []}
        self.data["attempts"].append(attempt)
        # Record ownership before the mutation so cleanup survives a lost create response.
        self.data["owned_agents"].append(name)
        self.persist()
        try:
            status, body = self.api(path + "/versions", "POST", {"definition": attempt["submitted_definition"]})
            attempt["create_http"] = status
            if status not in {200, 201, 202}:
                attempt.update(outcome="api_rejected", error=safe_diagnostic(body),
                               failure_category=failure_category(body))
                return attempt
            version = body.get("version")
            if not isinstance(version, str) or not re.fullmatch(r"[0-9]+", version):
                raise RuntimeError("Create response returned no valid candidate version")
            attempt["version"] = version
            deadline = time.monotonic() + self.timeout
            while time.monotonic() < deadline:
                status, body = self.api(path + f"/versions/{version}")
                attempt["history"].append({"at": timestamp(), "http": status, "status": body.get("status")})
                self.persist()
                if status in TRANSIENT:
                    time.sleep(self.interval)
                    continue
                if status != 200:
                    attempt.update(outcome="status_error", http=status)
                    return attempt
                attempt["returned_definition"] = returned_definition(body)
                state = body.get("status")
                if state == "active":
                    if attempt["returned_definition"]["image"] != image:
                        raise RuntimeError("Active candidate image differs from the experiment digest")
                    smoke.smoke_candidate(ENDPOINT, name, version, body, self.token, 300, self.interval, "")
                    attempt["outcome"] = "active_smoke_passed"
                    return attempt
                if state == "failed":
                    attempt.update(outcome="deployment_failed", error=safe_diagnostic(body.get("error")),
                                   failure_category=failure_category(body.get("error")))
                    return attempt
                if state != "creating":
                    attempt.update(outcome="unexpected_status", status=state)
                    return attempt
                time.sleep(min(self.interval, max(0, deadline - time.monotonic())))
            attempt["outcome"] = "timeout"
            return attempt
        except (urllib.error.URLError, TimeoutError, ValueError, RuntimeError) as error:
            attempt.update(outcome="experiment_error", error_type=type(error).__name__)
            return attempt
        finally:
            attempt["finished_at"] = timestamp()
            self.persist()
            self.cleanup(name)


def classify(attempts):
    omitted, control = attempts
    if control["outcome"] != "active_smoke_passed":
        return "inconclusive_positive_control_failed"
    if omitted["outcome"] == "active_smoke_passed":
        return "omission_works_authentication_inconclusive"
    if omitted["outcome"] == "api_rejected":
        return "omission_rejected_by_api"
    if omitted.get("failure_category") == "registry_authorization":
        return "explicit_authentication_required_in_tested_configuration"
    # Codes alone are insufficient to infer credentials caused the failure.
    return "omission_failed_review_registry_evidence"


def run(image, evidence, ledger, timeout):
    image_digest(image)
    if evidence["image"] != image or evidence["manifest"] != image_digest(image):
        raise ValueError("Prepared image evidence does not match the requested digest")
    if evidence["nonce_layer"] != evidence["layers"][-1] or not DIGEST.fullmatch(evidence["nonce_layer"]):
        raise ValueError("Invalid nonce-layer evidence")
    experiment = Experiment(ledger, timeout)
    experiment.data["image_evidence"] = evidence
    experiment.persist()
    try:
        before = experiment.snapshot_production()
        experiment.data["production_before"] = before
        probes, baseline = anonymous_baseline(evidence)
        experiment.data.update(anonymous_probes=probes, baseline=baseline, audit_available=False)
        experiment.persist()
        if baseline != "private_baseline_confirmed":
            experiment.data["conclusion"] = baseline
            raise RuntimeError(f"Experiment cannot proceed: {baseline}")
        experiment.attempt(image, None)
        experiment.attempt(image, CONNECTION)
        experiment.data["conclusion"] = classify(experiment.data["attempts"])
        after = experiment.snapshot_production()
        experiment.data["production_after"] = after
        if after != before:
            raise RuntimeError("Production agent metadata changed during the experiment")
        if experiment.data["conclusion"] == "inconclusive_positive_control_failed":
            raise RuntimeError("Authenticated positive control did not pass")
    finally:
        experiment.data["finished_at"] = timestamp()
        experiment.persist()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image")
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--ledger", default="registry-experiment.json")
    parser.add_argument("--nonce")
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--cleanup", action="store_true")
    parser.add_argument("--acknowledge-private-test", action="store_true")
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 1800:
        parser.error("--timeout must be between 1 and 1800 seconds")
    if args.cleanup:
        path = Path(args.ledger)
        if not path.exists():
            return 0
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("endpoint") != ENDPOINT:
            raise ValueError("Cleanup ledger has an unexpected endpoint")
        experiment = Experiment(args.ledger)
        experiment.data = data
        failures = []
        for name in list(data["owned_agents"]):
            try:
                experiment.cleanup(name)
            except (RuntimeError, ValueError, urllib.error.URLError, TimeoutError) as error:
                failures.append(f"{name}: {type(error).__name__}")
        if failures:
            raise RuntimeError("Residual owned resources: " + "; ".join(failures))
        return 0
    if not args.image:
        parser.error("--image is required")
    if args.prepare:
        if not args.nonce or not re.fullmatch(r"[0-9a-f]{32}", args.nonce):
            parser.error("--nonce must be a 32-character hexadecimal identifier")
        prepare(args.image, args.nonce, args.evidence)
    else:
        if not args.acknowledge_private_test:
            parser.error("--acknowledge-private-test is required")
        run(args.image, json.loads(Path(args.evidence).read_text(encoding="utf-8")), args.ledger, args.timeout)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        # Error text from network libraries can contain signed URLs or tokens.
        print(f"Registry experiment failed ({type(error).__name__}); inspect the sanitized ledger.", file=sys.stderr)
        sys.exit(1)
