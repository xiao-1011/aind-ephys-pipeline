#!/bin/bash
#SBATCH -A naiss2026-3-127
#SBATCH -t 24:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH -J spikesortingnf_dmc
#SBATCH -p main

set -euo pipefail

echo "Starting job $SLURM_JOB_ID"
date

############################
# Load conda environment
############################

CLEAN_PATH="$PATH"
source activate /cfs/klemming/projects/supr/dmclab/envs/aind-ephys
NF_BIN="$(which nextflow)"
export JAVA_HOME="$CONDA_PREFIX"
export JAVA_CMD="$CONDA_PREFIX/bin/java"
source deactivate
export PATH="$CLEAN_PATH"

############################
# Shared cache directories
############################

export NXF_APPTAINER_CACHEDIR="/cfs/klemming/projects/supr/dmclab/apptainer_cachedir"
export NUMBA_CACHE_DIR="/cfs/klemming/projects/supr/dmclab/numba_cachedir"
export HF_HOME="/cfs/klemming/projects/supr/dmclab/hf_cachedir"
export MPLCONFIGDIR="/cfs/klemming/projects/supr/dmclab/matplotlib_cachedir"
export KACHERY_DIR="/cfs/klemming/projects/supr/dmclab/kachery_cachedir"

############################
# Pipeline paths
############################

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline"

WORKDIR="/cfs/klemming/projects/supr/dmclab/nextflow_work"

LOGDIR="/cfs/klemming/projects/supr/dmclab/nextflow_logs"

export DATA_PATH="/cfs/klemming/projects/supr/dmclab/xiao/SGL_DATA/vr1220251126_g1"

export RESULTS_PATH="/cfs/klemming/projects/supr/dmclab/nextflow_results/vr1220251126_g1"

export PARAMS_FILE="$PIPELINE_PATH/pipeline/active_params.json"

############################
# Create directories
############################

mkdir -p "$WORKDIR"
mkdir -p "$RESULTS_PATH"
mkdir -p "$RESULTS_PATH/nextflow"
mkdir -p "$LOGDIR"

############################
# Select config
############################

if [ -f "$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config" ]; then
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config"
else
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm.config"
fi

echo "Using config file: $CONFIG_FILE"

############################
# Run Nextflow
############################

$NF_BIN \
    -C "$CONFIG_FILE" \
    -log "$LOGDIR/${SLURM_JOB_ID}.nextflow.log" \
    run "$PIPELINE_PATH/pipeline/main_multi_backend.nf" \
    -work-dir "$WORKDIR" \
    -resume \
    --params_file "$PARAMS_FILE" \
    --n_jobs 16 \
    --data_path "$DATA_PATH" \
    --results_path "$RESULTS_PATH" \
    -with-report "$LOGDIR/${SLURM_JOB_ID}_report.html" \
    -with-trace "$LOGDIR/${SLURM_JOB_ID}_trace.txt" \
    -with-timeline "$LOGDIR/${SLURM_JOB_ID}_timeline.html"

echo "Job finished"
date
