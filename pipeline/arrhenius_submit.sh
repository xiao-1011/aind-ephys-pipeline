#!/bin/bash
# Nextflow controller job for the NAISS Arrhenius HPC.
# The controller itself is lightweight; each pipeline step is submitted as its own Slurm job.
#SBATCH -A naissXXXX-XX-XX-cpu
#SBATCH --partition=cpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=3G
#SBATCH --time=2-00:00:00
#SBATCH --job-name=aind-ephys-nf
#SBATCH --output=%x-%j.out

set -euo pipefail

# Make nextflow (>= 26.04, Java 17+) available, e.g. via a conda environment
# conda activate env_nf

PROJECT_DIR="/nobackup/proj/disk/CHANGE_ME"
PIPELINE_PATH="$PROJECT_DIR/aind-ephys-pipeline"
export DATA_PATH="$PROJECT_DIR/data/CHANGE_ME"
export RESULTS_PATH="$PROJECT_DIR/results/CHANGE_ME"
WORKDIR="$PROJECT_DIR/nextflow_work"

export ARRHENIUS_CPU_ACCOUNT="naissXXXX-XX-XX-cpu"
export ARRHENIUS_GPU_ACCOUNT="naissXXXX-XX-XX-gpu"
export KS4_ARM64_SIF="$PROJECT_DIR/containers/aind-ephys-spikesort-kilosort4_1.4.0_arm64.sif"

# Apptainer images and caches must live outside $HOME on Arrhenius
export NXF_APPTAINER_CACHEDIR="$PROJECT_DIR/apptainer_cache"
export APPTAINER_CACHEDIR="$NXF_APPTAINER_CACHEDIR"
export NXF_HOME="$PROJECT_DIR/.nextflow"

mkdir -p "$RESULTS_PATH/nextflow" "$WORKDIR" "$NXF_APPTAINER_CACHEDIR"

# -C uses only this config (skips the Code Ocean pipeline/nextflow.config)
nextflow \
    -C "$PIPELINE_PATH/pipeline/nextflow_arrhenius.config" \
    -log "$RESULTS_PATH/nextflow/nextflow.log" \
    run "$PIPELINE_PATH/pipeline/main_multi_backend.nf" \
    -work-dir "$WORKDIR" \
    -resume
