#!/usr/bin/env bash
# Run the agent locally with hot reload. No Docker, no JFrog, no Azure.
#
#   ./run-local.sh            # echo mode
#   MODEL=1 ./run-local.sh    # model mode (needs az login + the two env vars below)
#
# Works on Linux, macOS, and Windows Git Bash / MSYS (venv layout differs there).
set -euo pipefail
cd "$(dirname "$0")"

PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "ERROR: no python found. Install Python 3.10+ or set PYTHON=/path/to/python"; exit 1; }
echo "==> Using $($PY --version 2>&1) at $(command -v "$PY")"

# venv layout: POSIX uses bin/, Windows uses Scripts/
venv_activate() {
  if   [ -f .venv/bin/activate ];     then echo .venv/bin/activate
  elif [ -f .venv/Scripts/activate ]; then echo .venv/Scripts/activate
  else echo ""; fi
}

ACTIVATE="$(venv_activate)"
if [ -z "$ACTIVATE" ]; then
  if [ -d .venv ]; then
    echo "==> Found an incomplete .venv, removing it"
    rm -rf .venv
  fi
  echo "==> Creating .venv"
  if ! "$PY" -m venv .venv; then
    echo
    echo "ERROR: could not create a virtual environment."
    echo "  Debian/Ubuntu/WSL : sudo apt install python3-venv python3-pip"
    echo "  Then re-run this script."
    exit 1
  fi
  ACTIVATE="$(venv_activate)"
  [ -n "$ACTIVATE" ] || { echo "ERROR: venv created but no activate script found under .venv"; exit 1; }
fi

echo "==> Activating ${ACTIVATE}"
# shellcheck disable=SC1090
source "$ACTIVATE"

echo "==> Installing dependencies"
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r requirements.txt

if [ "${MODEL:-0}" = "1" ]; then
  : "${FOUNDRY_PROJECT_ENDPOINT:?set FOUNDRY_PROJECT_ENDPOINT, e.g. https://<account>.services.ai.azure.com/api/projects/<project>}"
  : "${AZURE_AI_MODEL_DEPLOYMENT_NAME:?set AZURE_AI_MODEL_DEPLOYMENT_NAME, e.g. gpt-5-mini}"
  echo "==> MODEL mode -> ${AZURE_AI_MODEL_DEPLOYMENT_NAME} @ ${FOUNDRY_PROJECT_ENDPOINT}"
  echo "    (DefaultAzureCredential will use your 'az login' identity locally)"
else
  unset AZURE_AI_MODEL_DEPLOYMENT_NAME FOUNDRY_PROJECT_ENDPOINT 2>/dev/null || true
  echo "==> ECHO mode (no model call)"
fi

PORT="${PORT:-8088}"
echo "==> http://localhost:${PORT}   docs: http://localhost:${PORT}/docs   (Ctrl+C to stop)"
exec python -m uvicorn app:app --host 0.0.0.0 --port "${PORT}" --reload
