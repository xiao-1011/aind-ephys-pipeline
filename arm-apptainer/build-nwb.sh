#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Build NWB export SIF on Dardel login node
#
# Fixes hdmf/pynwb incompatibility in the base container:
#   hdmf 4.1.0 removed RegionBuilder, but pynwb 2.8.2 still imports it.
#
# Usage (login node — no sbatch needed, build is lightweight):
#   bash build-nwb.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

echo "=== Build started: $(date) ==="
echo "Node:     $(hostname)"
echo "Arch:     $(uname -m)"

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc"
CACHE_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache"
SIF_PATH="${CACHE_BASE}/apptainer/nwb-export.sif"
DEF_PATH="${PIPELINE_PATH}/arm-apptainer/nwb-export.def"

export APPTAINER_CACHEDIR="${CACHE_BASE}/apptainer-build-cache"
export APPTAINER_TMPDIR="${CACHE_BASE}/apptainer-build-tmp"

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────

ml PDC/24.11
ml apptainer/1.4.0-cpeGNU-24.11

mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$(dirname "$SIF_PATH")"

echo "DEF:  $DEF_PATH"
echo "SIF:  $SIF_PATH"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Building SIF ==="

[ -f "$SIF_PATH" ] && mv "$SIF_PATH" "${SIF_PATH}.bak"

apptainer build "$SIF_PATH" "$DEF_PATH"

BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
    echo "ERROR: apptainer build failed (exit $BUILD_EXIT)"
    [ -f "${SIF_PATH}.bak" ] && mv "${SIF_PATH}.bak" "$SIF_PATH"
    exit $BUILD_EXIT
fi

rm -f "${SIF_PATH}.bak"

echo ""
echo "=== Build succeeded: $(ls -lh "$SIF_PATH") ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Verify
# ─────────────────────────────────────────────────────────────────────────────

BIND="--bind /cfs/klemming/projects/supr/dmclab:/cfs/klemming/projects/supr/dmclab"
RUN="apptainer exec $BIND $SIF_PATH"

echo "=== Test: pynwb import ==="
$RUN python -c "
import pynwb
import hdmf
print(f'pynwb {pynwb.__version__}')
print(f'hdmf  {hdmf.__version__}')
from hdmf.build import ObjectMapper
print('Import OK')
print('PASS')
"

echo ""
echo "=== Test: spikeinterface + neuroconv import ==="
$RUN python -c "
import spikeinterface
import neuroconv
print(f'spikeinterface {spikeinterface.__version__}')
print(f'neuroconv      {neuroconv.__version__}')
print('PASS')
"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Cleaning build cache ==="
rm -rf "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

echo ""
echo "=== All tests PASSED: $(date) ==="
echo "SIF ready at: $SIF_PATH"
