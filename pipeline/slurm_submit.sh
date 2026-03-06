#!/bin/bash
#SBATCH -A naiss2026-3-127
#SBATCH -t 1:00:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH -J spikesortingnf_dmc
#SBATCH -p main


# modify this section to make the nextflow command available to your environment
# e.g., using a conda environment with nextflow installed

CLEAN_PATH="$PATH"
source activate nf-env
NF_BIN="$(which nextflow)"
export JAVA_HOME="$CONDA_PREFIX"
export JAVA_CMD="$CONDA_PREFIX/bin/java"
source deactivate
export PATH="$CLEAN_PATH"

export NXF_APPTAINER_CACHEDIR="/cfs/klemming/projects/supr/dmclab/apptainer_cachedir"
export NUMBA_CACHE_DIR="/cfs/klemming/projects/supr/dmclab/numba_cachedir"
export HF_HOME="/cfs/klemming/projects/supr/dmclab/hf_cachedir"
export MPLCONFIGDIR="/cfs/klemming/projects/supr/dmclab/matplotlib_cachedir"
export KACHERY_DIR="/cfs/klemming/projects/supr/dmclab/kachery_cachedir"

PIPELINE_PATH="$HOME/Private/aind-ephys-pipeline"
DATA_PATH="$HOME/cfs/klemming/projects/supr/dmclab/xiao/SGL_DATA/vr1320251126_g0"
RESULTS_PATH="$HOME/cfs/klemming/projects/supr/dmclab/xiao/output/vr1320251126_g0_output"
PARAMS_FILE="$PIPELINE_PATH/pipeline/active_params.json"
WORKDIR="$HOME/Private/aind-ephys-pipeline/pipeline"

export DATA_PATH RESULTS_PATH PARAMS_FILE

# check if nextflow_local_custom.config exists
if [ -f "$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config" ]; then
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm_custom.config"
else
    CONFIG_FILE="$PIPELINE_PATH/pipeline/nextflow_slurm.config"
fi
echo "Using config file: $CONFIG_FILE"

$NF_BIN \
    -C $CONFIG_FILE \
    -log $RESULTS_PATH/nextflow/nextflow.log \
    run $PIPELINE_PATH/pipeline/main_multi_backend.nf \
    -work-dir $WORKDIR \
    --params_file $PARAMS_FILE
