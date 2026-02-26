#!/bin/bash
#SBATCH -A naiss2026-3-127
#SBATCH -t 1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH -J spikesortingnf_dmc
#SBATCH -p shared


# modify this section to make the nextflow command available to your environment
# e.g., using a conda environment with nextflow installed

source activate nf-env

PIPELINE_PATH="$HOME/Private/aind-ephys-pipeline"
DATA_PATH="$HOME/Private/sample_dataset/nwb"
RESULTS_PATH="$HOME/Private/sample_dataset/output"
WORKDIR="$HOME/Private/aind-ephys-pipeline/pipeline"

# check if nextflow_local_custom.config exists
if [ -f "$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config" ]; then
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config"
else
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm.config"
fi
echo "Using config file: $CONFIG_FILE"

DATA_PATH=$DATA_PATH RESULTS_PATH=$RESULTS_PATH nextflow \
    -C $CONFIG_FILE \
    -log $RESULTS_PATH/nextflow/nextflow.log \
    run $PIPELINE_PATH/pipeline/main_multi_backend.nf \
    -work-dir $WORKDIR
    # additional parameters here
