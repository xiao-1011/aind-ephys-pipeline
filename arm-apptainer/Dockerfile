# KiloSort4 container for ARM64 (NVIDIA GH200 / Grace Hopper)
#
# NGC PyTorch base already ships CUDA 12.x, cuDNN, NCCL, and PyTorch
# optimized for Hopper (sm_90) on aarch64 -- no manual wheel fiddling needed.
#
# Build:
#   docker buildx build --platform linux/arm64 -t <registry>/aind-ephys-spikesort-kilosort4-arm:<tag> .
#
# Convert to Apptainer SIF (on the target cluster):
#   apptainer build kilosort4-arm.sif docker://<registry>/aind-ephys-spikesort-kilosort4-arm:<tag>

FROM nvcr.io/nvidia/pytorch:26.02-py3

ENV KILOSORT4_VERSION=4.0.38
ENV DEBIAN_FRONTEND=noninteractive

# FFTW for CPU-side FFT operations used by KiloSort4 / SpikeInterface
RUN apt-get update && apt-get install -y --no-install-recommends \
        libfftw3-dev \
    && rm -rf /var/lib/apt/lists/*

# Core spike-sorting stack
RUN pip install --no-cache-dir \
    kilosort==${KILOSORT4_VERSION} \
    spikeinterface[full]==0.103.0 \
    aind-data-schema==2.4.0 \
    aind-log-utils==0.2.3
