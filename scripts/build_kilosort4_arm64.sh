#!/bin/bash
# Build the aarch64 Kilosort4 image (environment/kilosort4_arm64.def) on an Arrhenius GH200 node.
# The image architecture follows the build node, so this must run on the gpu partition.
#
# Usage, from the repo root:
#   sbatch scripts/build_kilosort4_arm64.sh [output.sif]
#
# Besides the image, this writes <output>_libcufft.so.11 next to it: a copy of the image's
# libcufft.so.11 that nextflow_arrhenius.config binds over the one inside the image
# (see CUFFT_IMAGE_PATH below for why).
#SBATCH -A naiss2026-3-127-gpu
#SBATCH --partition=gpu
#SBATCH --gpus=1
#SBATCH --mem=100G
#SBATCH --time=02:00:00
#SBATCH --job-name=build-ks4-arm64
#SBATCH --output=build-ks4-arm64-%j.out

set -euo pipefail

USER_DIR="/nobackup/proj/disk/dmclab/personal/$USER"
SIF="${1:-$USER_DIR/containers/aind-ephys-spikesort-kilosort4_1.4.0_arm64.sif}"

# On Arrhenius, Apptainer mounts the image root through overlayfs, and libcufft.so.11 loaded
# from there fails every GPU FFT with CUFFT_INTERNAL_ERROR (torch matmul etc. are fine).
# The byte-identical file bound in from any plain filesystem works, so a copy is extracted
# next to the image and bound over this path at runtime. Keep the path in sync with
# nextflow_arrhenius.config (it follows the Python version of the base image).
CUFFT_IMAGE_PATH="/usr/local/lib/python3.12/site-packages/nvidia/cufft/lib/libcufft.so.11"
CUFFT_COPY="${SIF%.sif}_libcufft.so.11"

export APPTAINER_CACHEDIR="$USER_DIR/apptainer_cache/.apptainer"
unset SINGULARITY_CACHEDIR

# Unpacked build tree needs ~30 GB: use node-local /tmp if it has room, else project storage
if [[ $(df --output=avail -BG "${TMPDIR:-/tmp}" | tail -1 | tr -dc 0-9) -gt 60 ]]; then
    export APPTAINER_TMPDIR="${TMPDIR:-/tmp}/apptainer_tmp_$SLURM_JOB_ID"
else
    export APPTAINER_TMPDIR="$USER_DIR/apptainer_tmp/$SLURM_JOB_ID"
fi
mkdir -p "$APPTAINER_TMPDIR" "$APPTAINER_CACHEDIR" "$(dirname "$SIF")"
trap 'rm -rf "$APPTAINER_TMPDIR"' EXIT

echo "Node: $(hostname) ($(uname -m))  APPTAINER_TMPDIR=$APPTAINER_TMPDIR"
echo "Output: $SIF"

apptainer build --force "$SIF" environment/kilosort4_arm64.def

echo "=== Extracting libcufft to $CUFFT_COPY"
apptainer exec "$SIF" cat "$CUFFT_IMAGE_PATH" > "$CUFFT_COPY"
apptainer exec "$SIF" cmp "$CUFFT_IMAGE_PATH" "$CUFFT_COPY"

echo "=== Checking image (with the libcufft bind used by nextflow_arrhenius.config)"
apptainer exec --nv "$SIF" git --version
apptainer exec --nv -B "$CUFFT_COPY:$CUFFT_IMAGE_PATH" -B "$APPTAINER_TMPDIR" "$SIF" python -c "
import numpy, torch, kilosort, spikeinterface as si, aind_data_schema, log_schema
print('torch', torch.__version__, '| CUDA available:', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0))
x = torch.from_numpy(numpy.random.rand(1000, 64).astype('float32')).cuda()
print('numpy', numpy.__version__, '| numpy -> GPU -> numpy OK:', bool((x @ x.T).cpu().numpy().shape == (1000, 1000)))
# cuFFT is what Kilosort's highpass filter uses; it crashes when the CUDA libs are newer than the driver
for n in (1024, 60000, 60122):
    torch.fft.rfft(torch.randn(4, n, device='cuda'))
print('cuFFT OK')
print('kilosort', kilosort.__version__, '| spikeinterface', si.__version__)
import spikeinterface.sorters as ss
print('kilosort4 installed for SpikeInterface:', ss.Kilosort4Sorter.is_installed())
rec, gt = si.generate_ground_truth_recording(durations=[30.0], num_channels=32, seed=0)
sorting = ss.run_sorter('kilosort4', rec, folder='$APPTAINER_TMPDIR/ks4_smoke', verbose=False)
print('kilosort4 smoke test OK:', len(sorting.unit_ids), 'units found,', len(gt.unit_ids), 'simulated')
"
ls -lh "$SIF" "$CUFFT_COPY"
