#!/usr/bin/env bash
# Start the agent first. Set BASE to override http://localhost:8088.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/test_local.py" --base "${BASE:-http://localhost:8088}"
