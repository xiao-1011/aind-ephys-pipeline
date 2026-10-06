#!/bin/bash
# Nextflow controller job for the NAISS Arrhenius HPC.
# The controller itself is lightweight; each pipeline step is submitted as its own Slurm job.
#
# Usage:
#   sbatch pipeline/arrhenius_submit.sh <ecephys_session_dir> [results_dir]
#
# Sessions under raw_ecephys/<cohort>/<date>/<recording> are written to
# sorted_ecephys/<cohort>/<date>/<recording> unless results_dir is given.
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

RAW_ROOT="$USER_DIR/raw_ecephys"
SORTED_ROOT="$USER_DIR/sorted_ecephys"

export DATA_PATH="$(realpath -m "${1:?usage: sbatch arrhenius_submit.sh <ecephys_session_dir> [results_dir]}")"

# Mirror the raw layout: raw_ecephys/<cohort>/<date>/<recording> -> sorted_ecephys/<cohort>/<date>/<recording>
if [[ "$DATA_PATH" == "$RAW_ROOT"/* ]]; then
    SESSION_REL="${DATA_PATH#"$RAW_ROOT"/}"
elif [[ -n "${2:-}" ]]; then
    SESSION_REL="$(basename "$DATA_PATH")"
else
    echo "ERROR: $DATA_PATH is not under $RAW_ROOT; pass a results_dir as the second argument" >&2
    exit 64
fi
export RESULTS_PATH="$(realpath -m "${2:-$SORTED_ROOT/$SESSION_REL}")"
WORKDIR="$USER_DIR/nextflow_work/$SESSION_REL"

echo "DATA_PATH:    $DATA_PATH"
echo "RESULTS_PATH: $RESULTS_PATH"
echo "WORKDIR:      $WORKDIR"

export ARRHENIUS_CPU_ACCOUNT="naiss2026-3-127-cpu"
export ARRHENIUS_GPU_ACCOUNT="naiss2026-3-127-gpu"
export KS4_ARM64_SIF="$USER_DIR/containers/aind-ephys-spikesort-kilosort4_1.4.0_arm64.sif"
export KS4_ARM64_CUFFT="${KS4_ARM64_SIF%.sif}_libcufft.so.11"
if [[ ! -f "$KS4_ARM64_SIF" || ! -f "$KS4_ARM64_CUFFT" ]]; then
    echo "ERROR: missing $KS4_ARM64_SIF and/or $KS4_ARM64_CUFFT; run: sbatch scripts/build_kilosort4_arm64.sh" >&2
    exit 66
fi

# Apptainer images and Nextflow state must live outside $HOME on Arrhenius
export NXF_APPTAINER_CACHEDIR="$USER_DIR/apptainer_cache"
export APPTAINER_CACHEDIR="$NXF_APPTAINER_CACHEDIR"
export NXF_HOME="$USER_DIR/.nextflow"
# Same (strict) parser as local runs with Nextflow >= 26.04
export NXF_SYNTAX_PARSER=v2

mkdir -p "$RESULTS_PATH/nextflow" "$WORKDIR" "$NXF_APPTAINER_CACHEDIR"

# Launch from the per-session work dir so each session has its own .nextflow
# history: -resume then picks up that session's last run, and parallel sessions don't clash
cd "$WORKDIR"

# -C uses only this config (skips the Code Ocean pipeline/nextflow.config)
nextflow \
    -C "$PIPELINE_PATH/pipeline/nextflow_arrhenius.config" \
    -log "$RESULTS_PATH/nextflow/nextflow.log" \
    run "$PIPELINE_PATH/pipeline/main_multi_backend.nf" \
    -work-dir "$WORKDIR" \
    -resume
