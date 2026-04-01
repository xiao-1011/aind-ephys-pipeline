#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Build MountainSort5 CPU SIF on Dardel login node
#
# Adds mountainsort5 to the base container (SI 0.103.0).
# CPU-only — no GPU or ARM node needed.
#
# Usage (login node):
#   bash build-ms5.sh
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
SIF_PATH="${CACHE_BASE}/apptainer/mountainsort5-cpu.sif"
DEF_PATH="${PIPELINE_PATH}/arm-apptainer/mountainsort5-cpu.def"

# Use /tmp (tmpfs, RAM-backed) for build temp — much faster than Lustre for
# the thousands of small-file operations during pip install.
# Docker layer cache stays on Lustre (reusable across builds, large).
export APPTAINER_CACHEDIR="${CACHE_BASE}/apptainer-build-cache"
export APPTAINER_TMPDIR="/tmp/apptainer-build-$$"

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

if apptainer build "$SIF_PATH" "$DEF_PATH"; then
    rm -f "${SIF_PATH}.bak"
else
    BUILD_EXIT=$?
    echo "ERROR: apptainer build failed (exit $BUILD_EXIT)"
    [ -f "${SIF_PATH}.bak" ] && mv "${SIF_PATH}.bak" "$SIF_PATH"
    rm -rf "$APPTAINER_TMPDIR"
    exit $BUILD_EXIT
fi

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
print('PASS')
"

echo ""
echo "=== Test 2: MountainSort5 available ==="
$RUN python -c "
from spikeinterface.sorters import available_sorters
assert 'mountainsort5' in available_sorters(), 'mountainsort5 not available'
print('PASS')
"

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "=== Cleaning build temp ==="
rm -rf "$APPTAINER_TMPDIR"

echo ""
echo "=== All tests PASSED: $(date) ==="
echo "SIF ready at: $SIF_PATH"
