#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# PFC v3 — batch6: KS4 + TDC2 only on unprocessed Joana sessions
# (animals 1021218, 1053833, 1060138, 1031913, 1060360 — KS4+TDC2)
# ─────────────────────────────────────────────────────────────────────────────

#SBATCH -A naiss2026-3-127
#SBATCH -t 7-00:00:00
#SBATCH -n 1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH -J pfcv3-batch6
#SBATCH -p shared

set -euo pipefail

echo "Starting job ${SLURM_JOB_ID}"
date

# ─────────────────────────────────────────────────────────────────────────────
# User configuration
# ─────────────────────────────────────────────────────────────────────────────

# Staging dir of symlinks to the 23 unprocessed sessions
export DATA_PATH="/cfs/klemming/projects/supr/dmclab/Joana/ephys_batch6"

# ─────────────────────────────────────────────────────────────────────────────
# Shared infrastructure
# ─────────────────────────────────────────────────────────────────────────────

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc"

OUTPUT_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/pfcv3-batch6"
export RESULTS_PATH="${OUTPUT_BASE}/results"
WORKDIR="${OUTPUT_BASE}/work"
LOGDIR="${OUTPUT_BASE}/logs"

CACHE_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache"
export NXF_APPTAINER_CACHEDIR="${CACHE_BASE}/apptainer"
export NUMBA_CACHE_DIR="${CACHE_BASE}/numba"
export HF_HOME="${CACHE_BASE}/hf"
export MPLCONFIGDIR="${CACHE_BASE}/matplotlib"
export KACHERY_DIR="${CACHE_BASE}/kachery"

export CPU_SIF="${NXF_APPTAINER_CACHEDIR}/aind-ephys-pipeline-base.sif"
export MS5_SIF="${NXF_APPTAINER_CACHEDIR}/mountainsort5-cpu.sif"
export LUPIN_SIF="${NXF_APPTAINER_CACHEDIR}/lupin.sif"
export NWB_SIF="${NXF_APPTAINER_CACHEDIR}/nwb-export.sif"
export GPU_SIF="${NXF_APPTAINER_CACHEDIR}/kilosort4-arm.sif"

export APPTAINER_BIN_DIR="${PIPELINE_PATH}/pipeline/bin_gh200"

# ─────────────────────────────────────────────────────────────────────────────
# Environment setup
# ─────────────────────────────────────────────────────────────────────────────

ml PDC/24.11
ml miniconda3/25.3.1-1-cpeGNU-24.11
ml apptainer/1.4.0-cpeGNU-24.11

CLEAN_PATH="$PATH"
source activate /cfs/klemming/projects/supr/dmclab/envs/aind-ephys
NF_BIN="$(which nextflow)"
export JAVA_HOME="$CONDA_PREFIX"
export JAVA_CMD="$CONDA_PREFIX/bin/java"
source deactivate
export PATH="$CLEAN_PATH"

mkdir -p "${RESULTS_PATH}/nextflow"
mkdir -p "${WORKDIR}"
mkdir -p "${LOGDIR}"
mkdir -p "${CACHE_BASE}/apptainer"
mkdir -p "${CACHE_BASE}/numba"
mkdir -p "${CACHE_BASE}/hf"
mkdir -p "${CACHE_BASE}/matplotlib"
mkdir -p "${CACHE_BASE}/kachery"

# ─────────────────────────────────────────────────────────────────────────────
# Pre-cache HuggingFace models (UnitRefine classifiers)
# ─────────────────────────────────────────────────────────────────────────────

_hf_noise_model="SpikeInterface/UnitRefine_noise_neural_classifier_lightweight"
_hf_sua_model="SpikeInterface/UnitRefine_sua_mua_classifier_lightweight"

if [ ! -d "${HF_HOME}/hub/models--SpikeInterface--UnitRefine_noise_neural_classifier_lightweight/snapshots" ] || \
   [ ! -d "${HF_HOME}/hub/models--SpikeInterface--UnitRefine_sua_mua_classifier_lightweight/snapshots" ]; then
    echo "Pre-caching HuggingFace UnitRefine models..."
    apptainer exec \
        --bind /cfs/klemming/projects/supr/dmclab:/cfs/klemming/projects/supr/dmclab \
        "${LUPIN_SIF}" python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('${_hf_noise_model}')
snapshot_download('${_hf_sua_model}')
print('HuggingFace models cached successfully')
"
else
    echo "HuggingFace UnitRefine models already cached."
fi

export HF_HUB_OFFLINE=1

# ─────────────────────────────────────────────────────────────────────────────
# Run info
# ─────────────────────────────────────────────────────────────────────────────

echo "Pipeline:     ${PIPELINE_PATH}/projects/pfcv3/main.nf"
echo "Data path:    ${DATA_PATH}"
echo "Sessions:     $(find ${DATA_PATH} -maxdepth 1 -mindepth 1 -type l | wc -l) symlinks"
echo "Results path: ${RESULTS_PATH}"
echo "Work dir:     ${WORKDIR}"
echo "Sorters:      KS4 + TDC2 (SC2 + Lupin disabled)"
echo "Git commit:   $(git -C ${PIPELINE_PATH} rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ─────────────────────────────────────────────────────────────────────────────
# Run Nextflow — KS4 + TDC2 only
# ─────────────────────────────────────────────────────────────────────────────

cd "${OUTPUT_BASE}"

$NF_BIN \
    -C "${PIPELINE_PATH}/projects/pfcv3/nextflow.config" \
    -log "${LOGDIR}/${SLURM_JOB_ID}.nextflow.log" \
    run "${PIPELINE_PATH}/projects/pfcv3/main.nf" \
    -work-dir "${WORKDIR}" \
    -with-report   "${LOGDIR}/${SLURM_JOB_ID}_report.html" \
    -with-trace    "${LOGDIR}/${SLURM_JOB_ID}_trace.txt" \
    -with-timeline "${LOGDIR}/${SLURM_JOB_ID}_timeline.html" \
    -resume \
    --run_sc2 false \
    --run_lupin false

echo "Job finished"
date
