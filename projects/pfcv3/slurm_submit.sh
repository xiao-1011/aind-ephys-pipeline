#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# PFC v3 — SLURM submission script for NAISS Dardel
# Runs KS4 + SpykingCircus2 + MountainSort5 + Tridesclous2 + Lupin in parallel.
# Multi-GPU KS4: batches up to 4 probes per GPU node (4x savings).
#
# Usage:
#   sbatch slurm_submit.sh
#
# Edit the "User configuration" section below before submitting.
# ─────────────────────────────────────────────────────────────────────────────

#SBATCH -A naiss2026-3-127
#SBATCH -t 7-00:00:00
#SBATCH -n 1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH -J pfcv3-ephys-pipeline
#SBATCH -p shared

set -euo pipefail

echo "Starting job ${SLURM_JOB_ID}"
date

# ─────────────────────────────────────────────────────────────────────────────
# User configuration — adjust these paths for your session
# ─────────────────────────────────────────────────────────────────────────────

# Parent directory of your session folder(s).
export DATA_PATH="/cfs/klemming/projects/supr/dmclab/Joana/ephys_batch2"

# ─────────────────────────────────────────────────────────────────────────────
# Shared infrastructure — rarely needs editing
# ─────────────────────────────────────────────────────────────────────────────

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc"

# Output base for this project (separate from pfc v1)
OUTPUT_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/pfcv3-batch2"
export RESULTS_PATH="${OUTPUT_BASE}/results"
WORKDIR="${OUTPUT_BASE}/work"
LOGDIR="${OUTPUT_BASE}/logs"

# Cache directories (shared with pfc v1 and other projects)
CACHE_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache"
export NXF_APPTAINER_CACHEDIR="${CACHE_BASE}/apptainer"
export NUMBA_CACHE_DIR="${CACHE_BASE}/numba"
export HF_HOME="${CACHE_BASE}/hf"
export MPLCONFIGDIR="${CACHE_BASE}/matplotlib"
export KACHERY_DIR="${CACHE_BASE}/kachery"

# Container SIF paths
export CPU_SIF="${NXF_APPTAINER_CACHEDIR}/aind-ephys-pipeline-base.sif"
export MS5_SIF="${NXF_APPTAINER_CACHEDIR}/mountainsort5-cpu.sif"
export LUPIN_SIF="${NXF_APPTAINER_CACHEDIR}/lupin.sif"
export NWB_SIF="${NXF_APPTAINER_CACHEDIR}/nwb-export.sif"
export GPU_SIF="${NXF_APPTAINER_CACHEDIR}/kilosort4-arm.sif"

# Custom apptainer binary for GH200 (ARM) sorting nodes
export APPTAINER_BIN_DIR="${PIPELINE_PATH}/pipeline/bin_gh200"

# ─────────────────────────────────────────────────────────────────────────────
# Environment setup — load modules, then load nextflow from the shared conda env
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

# ─────────────────────────────────────────────────────────────────────────────
# Create output and cache directories
# ─────────────────────────────────────────────────────────────────────────────

mkdir -p "${RESULTS_PATH}/nextflow"
mkdir -p "${WORKDIR}"
mkdir -p "${LOGDIR}"
mkdir -p "${CACHE_BASE}/apptainer"
mkdir -p "${CACHE_BASE}/numba"
mkdir -p "${CACHE_BASE}/hf"
mkdir -p "${CACHE_BASE}/matplotlib"
mkdir -p "${CACHE_BASE}/kachery"

# ─────────────────────────────────────────────────────────────────────────────
# Pre-cache HuggingFace models (UnitRefine classifiers for advanced curation)
# Compute nodes may lack internet — cache on the shared queue node at startup.
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

# Force offline mode for compute nodes — models are pre-cached above.
# Prevents HuggingFace API rate limiting (429) when multiple tasks run in parallel.
export HF_HUB_OFFLINE=1

# ─────────────────────────────────────────────────────────────────────────────
# Print run info
# ─────────────────────────────────────────────────────────────────────────────

echo "Pipeline:     ${PIPELINE_PATH}/projects/pfcv3/main.nf"
echo "Data path:    ${DATA_PATH}"
echo "Results path: ${RESULTS_PATH}"
echo "Work dir:     ${WORKDIR}"
echo "CPU SIF:      ${CPU_SIF}"
echo "Lupin SIF:    ${LUPIN_SIF}"
echo "GPU SIF:      ${GPU_SIF}"
echo "Git commit:   $(git -C ${PIPELINE_PATH} rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ─────────────────────────────────────────────────────────────────────────────
# Run Nextflow
# ─────────────────────────────────────────────────────────────────────────────

# Nextflow stores its task cache in .nextflow/ relative to CWD.
# Always cd here so -resume finds the cache regardless of where sbatch was called.
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
    --run_ks4 false \
    --run_tdc2 false \
    --run_lupin false

echo "Job finished"
date
