#!/bin/bash
#SBATCH -A naiss2026-3-127
#SBATCH -t 12:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH -J spikesortingnf_dmc
#SBATCH -p main

set -euo pipefail

# Load nextflow from shared conda env
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate /cfs/klemming/projects/supr/dmclab/envs/aind-ephys

export JAVA_HOME="$CONDA_PREFIX"
export JAVA_CMD="$CONDA_PREFIX/bin/java"

export NXF_APPTAINER_CACHEDIR="/cfs/klemming/projects/supr/dmclab/apptainer_cachedir"
export NUMBA_CACHE_DIR="/cfs/klemming/projects/supr/dmclab/numba_cachedir"
export HF_HOME="/cfs/klemming/projects/supr/dmclab/hf_cachedir"
export MPLCONFIGDIR="/cfs/klemming/projects/supr/dmclab/matplotlib_cachedir"
export KACHERY_DIR="/cfs/klemming/projects/supr/dmclab/kachery_cachedir"

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline"
DATA_PATH="/cfs/klemming/projects/supr/dmclab/xiao/SGL_DATA/vr1320251126_g0"
RESULTS_PATH="/cfs/klemming/projects/supr/dmclab/xiao/output/vr1320251126_g0"
PARAMS_FILE="$PIPELINE_PATH/pipeline/active_params.json"
WORKDIR="/cfs/klemming/projects/supr/dmclab/xiao/nextflow_work"

mkdir -p "$RESULTS_PATH/nextflow"
mkdir -p "$WORKDIR"

export DATA_PATH RESULTS_PATH PARAMS_FILE

if [ -f "$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config" ]; then
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config"
else
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm.config"
fi

echo "Using config file: $CONFIG_FILE"
echo "Using pipeline path: $PIPELINE_PATH"
echo "Using params file: $PARAMS_FILE"

nextflow \
    -C "$CONFIG_FILE" \
    -log "$RESULTS_PATH/nextflow/nextflow.log" \
    run "$PIPELINE_PATH/pipeline/main_multi_backend.nf" \
    -work-dir "$WORKDIR" \
    -resume \
    --params_file "$PARAMS_FILE"
    --n_jobs 16
