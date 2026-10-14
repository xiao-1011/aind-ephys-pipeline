#!/bin/bash
# This launcher returns after submitting Slurm; no SSH/OpenCode session is needed.
# Usage: bash scripts/start_arrhenius_batch.sh <archive-name> [verified-pilot-report.json]
# Archives go to session_archives/<archive-name>/<cohort>/<date>/<session>.tar.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
USER_DIR="/nobackup/proj/disk/dmclab/personal/$USER"
NAME="${1:?Usage: start_arrhenius_batch.sh <archive-name> [verified-pilot-report.json]}"
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ && "$NAME" != . && "$NAME" != .. ]] || { echo "Archive name must be a single folder name: $NAME" >&2; exit 1; }
ARGS=(--archive-root "$USER_DIR/session_archives/$NAME")
if [[ -n "${2:-}" ]]; then
    ARGS+=(--pilot-report "$2")
fi
python3 "$SCRIPT_DIR/arrhenius_batch.py" start --user-root "$USER_DIR" "${ARGS[@]}"
