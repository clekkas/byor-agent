#!/usr/bin/env bash
# Smoke test a running agent. Start it first with ./run-local.sh in another terminal.
#
#   ./test-local.sh                          # against localhost:8088
#   BASE=http://localhost:9000 ./test-local.sh
#
set -uo pipefail
BASE="${BASE:-http://localhost:8088}"
PASS=0; FAIL=0

check() { # name, condition-output
  if [ -n "$2" ]; then echo "  PASS  $1"; PASS=$((PASS+1));
  else echo "  FAIL  $1"; FAIL=$((FAIL+1)); fi
}

echo "Testing ${BASE}"

echo
echo "[1] health"
H=$(curl -fsS "${BASE}/healthz" || true)
echo "      ${H}"
check "healthz returns ok" "$(echo "$H" | grep -o '"status":"ok"' || true)"

echo
echo "[2] string input"
R=$(curl -fsS -X POST "${BASE}/responses" -H 'Content-Type: application/json' \
  -d '{"input":"Respond with a short deployment confirmation."}' || true)
echo "      ${R:0:200}"
check "status completed"    "$(echo "$R" | grep -o '"status": *"completed"' || true)"
check "has output_text"     "$(echo "$R" | grep -o '"output_text"' || true)"
check "has output[] message" "$(echo "$R" | grep -o '"type": *"message"' || true)"

echo
echo "[3] message-array input (the shape Foundry is most likely to send)"
R2=$(curl -fsS -X POST "${BASE}/responses" -H 'Content-Type: application/json' \
  -d '{"input":[{"role":"user","content":[{"type":"input_text","text":"hello from the array shape"}]}]}' || true)
check "array input accepted" "$(echo "$R2" | grep -o 'array shape' || true)"

echo
echo "[4] versioned path alias"
R3=$(curl -fsS -X POST "${BASE}/v1/responses" -H 'Content-Type: application/json' \
  -d '{"input":"alias check"}' || true)
check "/v1/responses works" "$(echo "$R3" | grep -o '"output_text"' || true)"

echo
echo "[5] streaming (SSE)"
R4=$(curl -fsS -N -X POST "${BASE}/responses" -H 'Content-Type: application/json' \
  -d '{"input":"stream check","stream":true}' | head -c 400 || true)
echo "      ${R4:0:160}"
check "emits response.completed" "$(echo "$R4" | grep -o 'response.completed' || true)"

echo
echo "-------------------------------"
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] || exit 1
