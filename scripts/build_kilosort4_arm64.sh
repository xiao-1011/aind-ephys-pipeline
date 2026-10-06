#!/bin/bash
# Build the aarch64 Kilosort4 image (environment/kilosort4_arm64.def) on an Arrhenius GH200 node.
# The image architecture follows the build node, so this must run on the gpu partition.
#
# Usage, from the repo root:
#   sbatch scripts/build_kilosort4_arm64.sh [output.sif]
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

echo "=== Checking image"
apptainer exec --nv "$SIF" git --version
apptainer exec --nv "$SIF" python -c "
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
"
ls -lh "$SIF"
