#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Build Lupin sorter SIF on Dardel login node
#
# Upgrades SpikeInterface from 0.103.0 to 0.104.0 (first version with lupin).
# CPU-only — no GPU or ARM node needed.
#
# Usage (login node):
#   bash build-lupin.sh
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
SIF_PATH="${CACHE_BASE}/apptainer/lupin.sif"
DEF_PATH="${PIPELINE_PATH}/arm-apptainer/lupin.def"

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

echo "=== Test 1: SpikeInterface version ==="
$RUN python -c "
import spikeinterface
print(f'spikeinterface {spikeinterface.__version__}')
assert spikeinterface.__version__.startswith('0.104'), f'Expected 0.104.x, got {spikeinterface.__version__}'
print('PASS')
"

echo ""
echo "=== Test 2: Lupin sorter available ==="
$RUN python -c "
from spikeinterface.sorters import available_sorters
sorters = available_sorters()
print(f'Available sorters: {sorters}')
assert 'lupin' in sorters, f'lupin not in available sorters: {sorters}'
print('PASS')
"

echo ""
echo "=== Test 3: pynwb import (hdmf compatibility) ==="
$RUN python -c "
import pynwb
import hdmf
print(f'pynwb {pynwb.__version__}')
print(f'hdmf  {hdmf.__version__}')
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
