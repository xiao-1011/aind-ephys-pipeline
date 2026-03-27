#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# PFC project — SLURM submission script for NAISS Dardel
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
#SBATCH -J pfc-ephys-pipeline
#SBATCH -p main

set -euo pipefail

echo "Starting job ${SLURM_JOB_ID}"
date

# ─────────────────────────────────────────────────────────────────────────────
# User configuration — adjust these paths for your session
# ─────────────────────────────────────────────────────────────────────────────

# Parent directory of your session folder(s).
# Can be a single session:  .../SGL_DATA/vr1320251126_g0
# Or a directory of sessions: .../SGL_DATA   (pipeline discovers all probes)
export DATA_PATH="/cfs/klemming/projects/supr/dmclab/EDIT_ME/SGL_DATA"

# ─────────────────────────────────────────────────────────────────────────────
# Shared infrastructure — rarely needs editing
# ─────────────────────────────────────────────────────────────────────────────

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline"

# Output base for this project
OUTPUT_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/pfc"
export RESULTS_PATH="${OUTPUT_BASE}/results"
WORKDIR="${OUTPUT_BASE}/work"
LOGDIR="${OUTPUT_BASE}/logs"

# Cache directories (shared across all projects and runs)
CACHE_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache"
export NXF_APPTAINER_CACHEDIR="${CACHE_BASE}/apptainer"
export NUMBA_CACHE_DIR="${CACHE_BASE}/numba"
export HF_HOME="${CACHE_BASE}/hf"
export MPLCONFIGDIR="${CACHE_BASE}/matplotlib"
export KACHERY_DIR="${CACHE_BASE}/kachery"

# Container SIF paths
export CPU_SIF="${NXF_APPTAINER_CACHEDIR}/aind-ephys-pipeline-base.sif"
export GPU_SIF="${NXF_APPTAINER_CACHEDIR}/kilosort4-arm.sif"

# Custom apptainer binary for GH200 (ARM) sorting nodes
export APPTAINER_BIN_DIR="${PIPELINE_PATH}/pipeline/bin_gh200"

# ─────────────────────────────────────────────────────────────────────────────
# Environment setup — load nextflow from the shared conda env
# ─────────────────────────────────────────────────────────────────────────────

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

echo "Pipeline:     ${PIPELINE_PATH}/projects/pfc/main.nf"
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
    -C "${PIPELINE_PATH}/projects/pfc/nextflow.config" \
    -log "${LOGDIR}/${SLURM_JOB_ID}.nextflow.log" \
    run "${PIPELINE_PATH}/projects/pfc/main.nf" \
    -work-dir "${WORKDIR}" \
    -resume \
    -with-report   "${LOGDIR}/${SLURM_JOB_ID}_report.html" \
    -with-trace    "${LOGDIR}/${SLURM_JOB_ID}_trace.txt" \
    -with-timeline "${LOGDIR}/${SLURM_JOB_ID}_timeline.html"

echo "Job finished"
date
