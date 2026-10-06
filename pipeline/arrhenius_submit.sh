#!/bin/bash
# Nextflow controller job for the NAISS Arrhenius HPC.
# The controller itself is lightweight; each pipeline step is submitted as its own Slurm job.
#
# Usage:
#   sbatch pipeline/arrhenius_submit.sh <ecephys_session_dir> [results_dir]
#SBATCH -A naiss2026-3-127-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=5G
#SBATCH --time=3-00:00:00
#SBATCH --job-name=aind-ephys-nf
#SBATCH --output=%x-%j.out

set -euo pipefail

module load Java/21.0.11-bdist Nextflow/25.10.6-eb

USER_DIR="/nobackup/proj/disk/dmclab/personal/$USER"
PIPELINE_PATH="$USER_DIR/git_repo/aind-ephys-pipeline"

export DATA_PATH="${1:?usage: sbatch arrhenius_submit.sh <ecephys_session_dir> [results_dir]}"
export RESULTS_PATH="${2:-${DATA_PATH%/}_sorted}"
WORKDIR="$USER_DIR/nextflow_work/$(basename "${DATA_PATH%/}")"

export ARRHENIUS_CPU_ACCOUNT="naiss2026-3-127-cpu"
export ARRHENIUS_GPU_ACCOUNT="naiss2026-3-127-gpu"
export KS4_ARM64_SIF="$USER_DIR/containers/aind-ephys-spikesort-kilosort4_1.4.0_arm64.sif"

# Apptainer images and Nextflow state must live outside $HOME on Arrhenius
export NXF_APPTAINER_CACHEDIR="$USER_DIR/apptainer_cache"
export APPTAINER_CACHEDIR="$NXF_APPTAINER_CACHEDIR"
export NXF_HOME="$USER_DIR/.nextflow"
# Same (strict) parser as local runs with Nextflow >= 26.04
export NXF_SYNTAX_PARSER=v2

mkdir -p "$RESULTS_PATH/nextflow" "$WORKDIR" "$NXF_APPTAINER_CACHEDIR"

# -C uses only this config (skips the Code Ocean pipeline/nextflow.config)
nextflow \
    -C "$PIPELINE_PATH/pipeline/nextflow_arrhenius.config" \
    -log "$RESULTS_PATH/nextflow/nextflow.log" \
    run "$PIPELINE_PATH/pipeline/main_multi_backend.nf" \
    -work-dir "$WORKDIR" \
    -resume
