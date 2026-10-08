#!/bin/bash
# Submit from repo root after the image build:
# sbatch scripts/verify_curation_si4830.sh <failed-task> <reference-analyzer> [output-dir]
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=12
#SBATCH --mem=32G
#SBATCH --time=01:00:00
#SBATCH --job-name=verify-curation-si4830

set -euo pipefail
REPO="${SI4830_REPO:-${SLURM_SUBMIT_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}}"
USER_DIR="/nobackup/proj/disk/dmclab/personal/$USER"
TASK="$(realpath "${1:?provide failed Nextflow curation task directory}")"
REFERENCE="$(realpath "${2:?provide a successful postprocessing analyzer from the retained session}")"
OUT="${3:-$USER_DIR/session_log/si4830_verify_${SLURM_JOB_ID:?submit with sbatch}}"
BASE="${SI4830_BASE_IMAGE:-$USER_DIR/apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img}"
SIF="${CURATION_SIF:-$USER_DIR/containers/aind-ephys-curation_1.4.0_si4830.sif}"
[[ ! -e "$OUT" && -d "$TASK/capsule/code" && -d "$REFERENCE" ]]
sha256sum --check "$SIF.sha256"
mkdir -p "$OUT/home" "$OUT/hf-cache" "$OUT/numba" "$OUT/matplotlib"
OUT="$(realpath "$OUT")"
apptainer exec "$SIF" cat /opt/si4830/provenance.json > "$OUT/image_provenance.json"
cp "$SIF.sha256" "$OUT/image.sha256"
# All data/recordings for these two inputs live under the retained session work root.
WORK="$(dirname "$(dirname "$TASK")")"
[[ "$REFERENCE" == "$WORK/"* ]]
ENV="HF_HOME=$OUT/hf-cache,NUMBA_CACHE_DIR=$OUT/numba,MPLCONFIGDIR=$OUT/matplotlib"
ENV+=",N_JOBS_EXT=${SLURM_CPUS_PER_TASK:-12},OPENBLAS_NUM_THREADS=1,OMP_NUM_THREADS=1,PYTHONDONTWRITEBYTECODE=1"
CONTAINER=(apptainer exec --home "$OUT/home" -B "$USER_DIR" -B "$WORK:$WORK:ro" --env "$ENV")
SCRIPT="$REPO/scripts/verify_curation_si4830.py"
echo "Verification output: $OUT"
"${CONTAINER[@]}" "$SIF" /opt/conda/bin/python -u "$SCRIPT" prepare --output "$OUT" --task "$TASK" --reference "$REFERENCE"
CONTAINER=(apptainer exec --home "$OUT/home" -B "$USER_DIR" -B "$WORK:$WORK:ro" --env "$ENV,HF_HUB_OFFLINE=1")
"${CONTAINER[@]}" "$BASE" /opt/conda/bin/python -u "$SCRIPT" baseline --output "$OUT"
"${CONTAINER[@]}" "$SIF" /opt/conda/bin/python -u "$SCRIPT" patched --output "$OUT"
"${CONTAINER[@]}" "$SIF" /opt/conda/bin/python -u "$SCRIPT" capsule --output "$OUT"
