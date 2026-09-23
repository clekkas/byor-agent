"""
Interactive chat with the running agent. Standard library only.

    python chat_local.py                       # interactive REPL
    python chat_local.py "one-off question"    # ask once and exit
    python chat_local.py --stream "question"   # watch the SSE stream
    python chat_local.py --base http://localhost:9000

Type 'exit' or Ctrl+C to quit the REPL.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request


def ask(base, prompt, stream=False, timeout=120):
    payload = {"input": prompt}
    if stream:
        payload["stream"] = True
    req = urllib.request.Request(
        f"{base}/responses",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode()
    elapsed = time.time() - started

    if stream:
        return body, elapsed

    data = json.loads(body)
    if data.get("status") == "failed":
        return f"[agent error] {data.get('error', {}).get('message', 'unknown')}", elapsed
    return data.get("output_text", "(no output_text in response)"), elapsed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prompt", nargs="*", help="ask once and exit")
    ap.add_argument("--base", default="http://localhost:8088")
    ap.add_argument("--stream", action="store_true", help="print the raw SSE stream")
    ap.add_argument("--raw", action="store_true", help="print the full JSON envelope")
    args = ap.parse_args()
    base = args.base.rstrip("/")

    try:
        with urllib.request.urlopen(f"{base}/healthz", timeout=10) as r:
            health = json.loads(r.read().decode())
        print(f"Connected to {base}  (mode: {health.get('mode')}, agent: {health.get('agent')})")
    except Exception as e:
        print(f"Cannot reach {base}: {e}")
        print("Start it first:  python run_local.py --model")
        return 1

    if health.get("mode") == "echo":
        print("NOTE: agent is in echo mode - it will not call the model.")
        print("      Restart with:  python run_local.py --model")

    def show(prompt):
        try:
            out, secs = ask(base, prompt, stream=args.stream)
        except urllib.error.HTTPError as e:
            print(f"\nHTTP {e.code}: {e.read().decode()[:500]}\n")
            return
        except Exception as e:
            print(f"\nRequest failed: {e}\n")
            return
        print(f"\n{out}\n  [{secs:.1f}s]\n")

    if args.prompt:
        show(" ".join(args.prompt))
        return 0

    print("Type a question, or 'exit' to quit.\n")
    while True:
        try:
            q = input("you> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not q:
            continue
        if q.lower() in ("exit", "quit", ":q"):
            return 0
        show(q)


if __name__ == "__main__":
    sys.exit(main())
