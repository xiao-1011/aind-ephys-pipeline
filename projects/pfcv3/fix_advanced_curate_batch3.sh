#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# One-off fix: re-run ADVANCED_CURATE on the 6 KS4 analyzers that OOM-killed
# at 16 GB during pfcv3-batch3 (job 20416227).
#
# Runs at 32 GB, outside Nextflow, writing outputs directly into the published
# results dirs. SLURM array parallelizes the 6 probes.
#
# Usage (from Dardel):
#   sbatch /cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc/projects/pfcv3/fix_advanced_curate_batch3.sh
# ─────────────────────────────────────────────────────────────────────────────

#SBATCH -A naiss2026-3-127
#SBATCH -t 00:45:00
#SBATCH -n 1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH -p shared
#SBATCH -J fix-advcurate-batch3
#SBATCH --array=0-5
#SBATCH --output=/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/pfcv3-batch3/logs/fix_advcurate_%A_%a.out

set -euo pipefail

PROBES=(
    986168_day1_g0/986168_day1_g0_imec1
    986168_day3_g0/986168_day3_g0_imec1
    986171_day3_g0/986171_day3_g0_imec0
    986235_day2_g0/986235_day2_g0_imec0
    986235_day2_g0/986235_day2_g0_imec1
    986235_day3_g0/986235_day3_g0_imec1
)

PROBE="${PROBES[$SLURM_ARRAY_TASK_ID]}"
RESULTS=/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/pfcv3-batch3/results
PIPELINE=/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc
CACHE_BASE=/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache
LUPIN_SIF="${CACHE_BASE}/apptainer/lupin.sif"

ml PDC/24.11
ml apptainer/1.4.0-cpeGNU-24.11

export HF_HOME="${CACHE_BASE}/hf"
export HF_HUB_OFFLINE=1

PROBE_DIR="${RESULTS}/${PROBE}"
echo "[$(date)] Task ${SLURM_ARRAY_TASK_ID}: ${PROBE}"
echo "  probe_dir : ${PROBE_DIR}"
echo "  analyzer  : ${PROBE_DIR}/analyzer_kilosort4"

if [ ! -d "${PROBE_DIR}/analyzer_kilosort4" ]; then
    echo "ERROR: analyzer_kilosort4 not found at ${PROBE_DIR}"
    exit 1
fi

cd "${PROBE_DIR}"

apptainer exec \
    --bind /cfs/klemming/projects/supr/dmclab:/cfs/klemming/projects/supr/dmclab \
    --bind "${HF_HOME}":/root/.cache/huggingface \
    "${LUPIN_SIF}" \
    python "${PIPELINE}/projects/pfcv3/scripts/07-advanced-curate.py" \
        "${PROBE_DIR}" \
        --analyzer_folder "${PROBE_DIR}/analyzer_kilosort4"

echo "[$(date)] Done: ${PROBE}"
