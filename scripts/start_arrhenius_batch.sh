#!/bin/bash
# This launcher returns after submitting Slurm; no SSH/OpenCode session is needed.
# Usage: bash scripts/start_arrhenius_batch.sh [verified-pilot-report.json]
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
USER_DIR="/nobackup/proj/disk/dmclab/personal/$USER"
ARGS=()
if [[ -n "${1:-}" ]]; then
    ARGS=(--pilot-report "$1")
fi
python3 "$SCRIPT_DIR/arrhenius_batch.py" start --user-root "$USER_DIR" "${ARGS[@]}"
