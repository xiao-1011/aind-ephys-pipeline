#!/bin/bash
# Replay only the capsule phase of an existing isolated verification.
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=12
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --job-name=replay-curation-si4830

set -euo pipefail
REPO="${SI4830_REPO:-${SLURM_SUBMIT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}}"
USER_DIR="/nobackup/proj/disk/dmclab/personal/$USER"
OUT="$(realpath "${1:?supply verification directory}")"
SIF="${CURATION_SIF:-$USER_DIR/containers/aind-ephys-curation_1.4.0_si4830.sif}"
[[ "$OUT" == "$USER_DIR/session_log/si4830_verify_"* && -f "$OUT/baseline.json" && -f "$OUT/patched.json" ]]
sha256sum --check "$SIF.sha256"
cmp "$OUT/image.sha256" "$SIF.sha256"
WORK="$(python3 - "$OUT" <<'PY'
import json, pathlib, sys
task=pathlib.Path(json.loads((pathlib.Path(sys.argv[1])/'inputs.json').read_text())['task'])
print(task.parent.parent)
PY
)"
[[ -d "$WORK" ]]
apptainer exec --home "$OUT/home" -B "$USER_DIR" -B "$WORK:$WORK:ro" \
    --env "HF_HOME=$OUT/hf-cache,NUMBA_CACHE_DIR=$OUT/numba,MPLCONFIGDIR=$OUT/matplotlib,N_JOBS_EXT=${SLURM_CPUS_PER_TASK:-12},OPENBLAS_NUM_THREADS=1,OMP_NUM_THREADS=1,PYTHONDONTWRITEBYTECODE=1" \
    "$SIF" /opt/conda/bin/python -u "$REPO/scripts/verify_curation_si4830.py" capsule --output "$OUT"
