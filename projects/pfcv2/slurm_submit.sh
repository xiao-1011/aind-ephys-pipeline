#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# PFC v2 — SLURM submission script for NAISS Dardel
# Runs KS4 + SpykingCircus2 + MountainSort5 + Tridesclous2 in parallel.
#
# Usage:
#   sbatch slurm_submit.sh
#
# Edit the "User configuration" section below before submitting.
# ─────────────────────────────────────────────────────────────────────────────

#SBATCH -A naiss2026-3-127
#SBATCH -t 12:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH -J pfcv2-ephys-pipeline
#SBATCH -p main

set -euo pipefail

echo "Starting job ${SLURM_JOB_ID}"
date

# ─────────────────────────────────────────────────────────────────────────────
# User configuration — adjust these paths for your session
# ─────────────────────────────────────────────────────────────────────────────

# Parent directory of your session folder(s).
export DATA_PATH="/cfs/klemming/projects/supr/dmclab/Joana/Raw_data/999770/999770_day1_g0"

# ─────────────────────────────────────────────────────────────────────────────
# Shared infrastructure — rarely needs editing
# ─────────────────────────────────────────────────────────────────────────────

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc"

# Output base for this project (separate from pfc v1)
OUTPUT_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/pfcv2"
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
# Print run info
# ─────────────────────────────────────────────────────────────────────────────

echo "Pipeline:     ${PIPELINE_PATH}/projects/pfcv2/main.nf"
echo "Data path:    ${DATA_PATH}"
echo "Results path: ${RESULTS_PATH}"
echo "Work dir:     ${WORKDIR}"
echo "CPU SIF:      ${CPU_SIF}"
echo "GPU SIF:      ${GPU_SIF}"
echo "Git commit:   $(git -C ${PIPELINE_PATH} rev-parse --short HEAD 2>/dev/null || echo unknown)"

# ─────────────────────────────────────────────────────────────────────────────
# Run Nextflow
# ─────────────────────────────────────────────────────────────────────────────

$NF_BIN \
    -C "${PIPELINE_PATH}/projects/pfcv2/nextflow.config" \
    -log "${LOGDIR}/${SLURM_JOB_ID}.nextflow.log" \
    run "${PIPELINE_PATH}/projects/pfcv2/main.nf" \
    -work-dir "${WORKDIR}" \
    -resume \
    -with-report   "${LOGDIR}/${SLURM_JOB_ID}_report.html" \
    -with-trace    "${LOGDIR}/${SLURM_JOB_ID}_trace.txt" \
    -with-timeline "${LOGDIR}/${SLURM_JOB_ID}_timeline.html"

echo "Job finished"
date
