"""
Smoke test the agent - no bash, no PowerShell, no execution policy, no line endings.

Start the agent first, then:

    python test_local.py
    python test_local.py --base http://localhost:9000

Uses only the Python standard library.
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

PASS = 0
FAIL = 0

# Works in BOTH modes: echo repeats the prompt back, and a model follows the
# instruction. Either way the token only appears if the server parsed the nested
# array correctly, which is what this check is actually testing.
PROBE = "Reply with exactly this token and nothing else: ARRAYOK"


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}{('  -> ' + detail) if detail else ''}")


def get(url):
    with urllib.request.urlopen(url, timeout=15) as r:
        return json.loads(r.read().decode())


def post(url, payload, raw=False):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        body = r.read().decode()
    return body if raw else json.loads(body)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8088")
    base = ap.parse_args().base.rstrip("/")

    print(f"Testing {base}")

    print("\n[1] health")
    mode = "unknown"
    try:
        h = get(f"{base}/healthz")
        print(f"      {h}")
        mode = h.get("mode", "unknown")
        check("healthz returns ok", h.get("status") == "ok")
    except Exception as e:
        check("healthz returns ok", False, str(e))
        print("\nAgent not reachable. Is it running? (python run_local.py, or docker run)")
        return 1

    print("\n[2] string input")
    try:
        r = post(f"{base}/responses", {"input": "Respond with a short deployment confirmation."})
        print(f"      {r.get('output_text', '')[:160]}")
        check("status completed", r.get("status") == "completed", str(r.get("status")))
        check("has output_text", bool(r.get("output_text")))
        check("has output[] message", bool(r.get("output")) and r["output"][0].get("type") == "message")
    except Exception as e:
        check("string input", False, str(e))

    print("\n[3] message-array input (the shape Foundry is most likely to send)")
    try:
        r2 = post(
            f"{base}/responses",
            {"input": [{"role": "user", "content": [{"type": "input_text", "text": PROBE}]}]},
        )
        out = r2.get("output_text", "")
        print(f"      {out[:120]}")
        check("array input accepted", "ARRAYOK" in out, out[:80])
    except Exception as e:
        check("array input accepted", False, str(e))

    print("\n[4] versioned path alias")
    try:
        r3 = post(f"{base}/v1/responses", {"input": "alias check"})
        check("/v1/responses works", bool(r3.get("output_text")))
    except Exception as e:
        check("/v1/responses works", False, str(e))

    print("\n[5] streaming (SSE)")
    try:
        raw = post(f"{base}/responses", {"input": "stream check", "stream": True}, raw=True)
        print(f"      {raw[:140].replace(chr(10), ' ')}")
        check("emits response.completed", "response.completed" in raw)
    except Exception as e:
        check("emits response.completed", False, str(e))

    print("\n-------------------------------")
    print(f"  {PASS} passed, {FAIL} failed   (mode: {mode})")
    if mode == "model":
        print("  NOTE: this agent is in MODEL mode. A container started with no env vars")
        print("        reports mode=echo - if you meant to test the container, check")
        print("        'docker ps' and stop any local run_local.py holding the port.")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
