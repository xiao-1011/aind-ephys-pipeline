#!/bin/bash
# ---------------------------------------------------------------------------
# multishankv2-local — submission script for local workstation
# RTX A4000 (x86, 16 GB VRAM), 32 CPUs, 188 GB RAM
#
# Edit the "User configuration" section, then run:
#   bash run_local.sh
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# User configuration — edit these before running
# ---------------------------------------------------------------------------

# Recording to process — copy it to SSD first for fast I/O:
#   cp -r /media/data/data_26/YOUR_SESSION /home/recordings/
# Then point DATA_PATH at the SSD copy:
export DATA_PATH="${DATA_PATH:-/media/data/Neuropix/2026-05-25_1021202_reaching_g0}"

# Results go to HDD (permanent, written once at the end)
RESULTS_BASE="/media/data/ephys-pipeline-output"

# Session label used to name results and work dirs (set to something meaningful)
SESSION_LABEL="$(basename ${DATA_PATH})"

# ---------------------------------------------------------------------------
# Shared configuration — rarely needs editing
# ---------------------------------------------------------------------------

PIPELINE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NF_CONFIG="${PIPELINE_PATH}/projects/multishankv2-local/nextflow.config"
NF_MAIN="${PIPELINE_PATH}/projects/multishankv2-local/main.nf"

export RESULTS_PATH="${RESULTS_BASE}/${SESSION_LABEL}/results"
WORKDIR="/home/anil/ephys-work/${SESSION_LABEL}"    # SSD: fast I/O for intermediate files
LOGDIR="${RESULTS_BASE}/${SESSION_LABEL}/logs"

# Cache dirs on HDD (Docker images, HF models — read at startup only, speed irrelevant)
CACHE_BASE="/media/data/ephys-pipeline-cache"
export NUMBA_CACHE_DIR="${CACHE_BASE}/numba"
export HF_HOME="${CACHE_BASE}/hf"
export MPLCONFIGDIR="${CACHE_BASE}/matplotlib"

# Docker images
CPU_IMAGE="ghcr.io/allenneuraldynamics/aind-ephys-pipeline-base:si-0.103.0"
GPU_IMAGE="ghcr.io/allenneuraldynamics/aind-ephys-spikesort-kilosort4:si-0.103.0"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

echo "=== Pre-flight checks ==="

# 1. Docker
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found. Install it first:"
    echo "  sudo apt-get install docker.io"
    echo "  sudo usermod -aG docker \$USER  # then log out/in"
    exit 1
fi
if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon not running or no permission."
    echo "  Try: sudo systemctl start docker"
    echo "  Or:  sudo usermod -aG docker \$USER  # then log out/in"
    exit 1
fi
echo "  [OK] Docker: $(docker --version)"

# 2. NVIDIA container toolkit
if ! docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi &>/dev/null; then
    echo "ERROR: GPU not accessible inside Docker containers."
    echo "  Install NVIDIA container toolkit:"
    echo "  https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
    exit 1
fi
echo "  [OK] NVIDIA GPU accessible in Docker"

# 3. Nextflow
if ! command -v nextflow &>/dev/null; then
    echo "ERROR: nextflow not found. Install it:"
    echo "  sudo apt-get install -y default-jre"
    echo "  curl -s https://get.nextflow.io | bash"
    echo "  sudo mv nextflow /usr/local/bin/"
    exit 1
fi
echo "  [OK] Nextflow: $(nextflow -version 2>&1 | head -1)"

# 4. Data path
if [ ! -d "${DATA_PATH}" ]; then
    echo "ERROR: DATA_PATH not found: ${DATA_PATH}"
    echo "  Edit the User configuration section of this script."
    exit 1
fi
echo "  [OK] DATA_PATH: ${DATA_PATH}"

echo ""

# ---------------------------------------------------------------------------
# Pull Docker images (explicit pull so errors are clear)
# ---------------------------------------------------------------------------

echo "=== Pulling Docker images (skip if already local) ==="
for img in "${CPU_IMAGE}" "${GPU_IMAGE}"; do
    if docker image inspect "$img" &>/dev/null; then
        echo "  [OK] cached: $img"
    else
        echo "  Pulling: $img"
        docker pull "$img"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# Create output and cache directories
# ---------------------------------------------------------------------------

mkdir -p "${RESULTS_PATH}/nextflow"
mkdir -p "${WORKDIR}"
mkdir -p "${LOGDIR}"
mkdir -p "${CACHE_BASE}/numba"
mkdir -p "${CACHE_BASE}/hf"
mkdir -p "${CACHE_BASE}/matplotlib"

# ---------------------------------------------------------------------------
# Pre-cache HuggingFace models (UnitRefine — needed for ADVANCED_CURATE)
# This runs on the login node inside Docker so compute tasks can run offline.
# ---------------------------------------------------------------------------

_hf_noise_model="SpikeInterface/UnitRefine_noise_neural_classifier_lightweight"
_hf_sua_model="SpikeInterface/UnitRefine_sua_mua_classifier_lightweight"

if [ ! -d "${HF_HOME}/hub/models--SpikeInterface--UnitRefine_noise_neural_classifier_lightweight/snapshots" ] || \
   [ ! -d "${HF_HOME}/hub/models--SpikeInterface--UnitRefine_sua_mua_classifier_lightweight/snapshots" ]; then
    echo "=== Pre-caching HuggingFace UnitRefine models ==="
    docker run --rm \
        -v "${HF_HOME}:/root/.cache/huggingface" \
        "${CPU_IMAGE}" python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('${_hf_noise_model}')
snapshot_download('${_hf_sua_model}')
print('HuggingFace models cached successfully')
"
    echo ""
else
    echo "=== HuggingFace UnitRefine models already cached. ==="
    echo ""
fi

# Force offline mode so compute tasks don't hit the HF API
export HF_HUB_OFFLINE=1

# ---------------------------------------------------------------------------
# Print run info
# ---------------------------------------------------------------------------

echo "=== Run info ==="
echo "  Pipeline:     ${NF_MAIN}"
echo "  Config:       ${NF_CONFIG}"
echo "  Data path:    ${DATA_PATH}"
echo "  Results path: ${RESULTS_PATH}"
echo "  Work dir:     ${WORKDIR}"
echo "  Git commit:   $(git -C ${PIPELINE_PATH} rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo ""

# ---------------------------------------------------------------------------
# Run Nextflow

# ---------------------------------------------------------------------------

mkdir -p "${RESULTS_BASE}/${SESSION_LABEL}"
cd "${RESULTS_BASE}/${SESSION_LABEL}"

nextflow \
    -C "${NF_CONFIG}" \
    -log "${LOGDIR}/nextflow.log" \
    run "${NF_MAIN}" \
    -work-dir "${WORKDIR}" \
    -resume \
    -with-report   "${LOGDIR}/report.html" \
    -with-trace    "${LOGDIR}/trace.txt" \
    -with-timeline "${LOGDIR}/timeline.html" \
    "$@"

echo ""
echo "Job finished"
date
