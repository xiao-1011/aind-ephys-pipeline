#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Build KiloSort4 ARM SIF on Dardel GH200 node (batch mode)
#
# Usage:
#   sbatch build-ks4.sh
# ─────────────────────────────────────────────────────────────────────────────

#SBATCH -A naiss2026-3-127-gh
#SBATCH -p gpugh
#SBATCH -t 02:00:00
#SBATCH -n 1
#SBATCH -c 16
#SBATCH --gpus=1
#SBATCH -J build-ks4-arm
#SBATCH -o build-ks4-%j.log

set -euo pipefail
trap 'rm -rf "$APPTAINER_TMPDIR" 2>/dev/null' EXIT

echo "=== Build started: $(date) ==="
echo "Job ID:   ${SLURM_JOB_ID}"
echo "Node:     $(hostname)"
echo "Arch:     $(uname -m)"

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

PIPELINE_PATH="/cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc"
CACHE_BASE="/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache"
SIF_PATH="${CACHE_BASE}/apptainer/kilosort4-arm-test.sif"
DEF_PATH="${PIPELINE_PATH}/arm-apptainer/kilosort4-arm.def"

# Use /tmp for build temp — faster than Lustre for small-file operations.
# On GH200 nodes /tmp may be tmpfs or local NVMe; either is faster than Lustre.
# Docker layer cache stays on Lustre (reusable across builds, large).
export APPTAINER_CACHEDIR="${CACHE_BASE}/apptainer-build-cache"
export APPTAINER_TMPDIR="/tmp/apptainer-build-$$"

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────

ml systemdefault/1.0.0
ml apptainer/1.4.4

mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR" "$(dirname "$SIF_PATH")"

echo "DEF:  $DEF_PATH"
echo "SIF:  $SIF_PATH"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Building SIF ==="

# Remove old SIF so a failed build doesn't leave a stale file
[ -f "$SIF_PATH" ] && mv "$SIF_PATH" "${SIF_PATH}.bak"

apptainer build --mksquashfs-args "-comp xz" "$SIF_PATH" "$DEF_PATH"

BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
    echo "ERROR: apptainer build failed (exit $BUILD_EXIT)"
    # Restore backup if build failed
    [ -f "${SIF_PATH}.bak" ] && mv "${SIF_PATH}.bak" "$SIF_PATH"
    exit $BUILD_EXIT
fi

# Remove backup
rm -f "${SIF_PATH}.bak"

echo ""
echo "=== Build succeeded: $(ls -lh "$SIF_PATH") ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Verification tests
# ─────────────────────────────────────────────────────────────────────────────

BIND="--bind /cfs/klemming/projects/supr/dmclab:/cfs/klemming/projects/supr/dmclab"
RUN="apptainer exec --nv $BIND $SIF_PATH"
FAILURES=0

run_test() {
    local name="$1"; shift
    echo "=== $name ==="
    if "$@"; then
        echo ""
    else
        echo "FAIL ($name)"
        echo ""
        FAILURES=$((FAILURES + 1))
    fi
}

run_test "Test 1: Check OPENBLAS_NUM_THREADS is set" \
$RUN python -c "
import os
val = os.environ.get('OPENBLAS_NUM_THREADS', 'NOT SET')
print(f'OPENBLAS_NUM_THREADS = {val}')
assert val == '64', f'Expected 64, got {val}'
print('PASS')
"

run_test "Test 2: LD_PRELOAD resolves" \
$RUN python -c "
import os, ctypes
preload = os.environ.get('LD_PRELOAD', 'NOT SET')
print(f'LD_PRELOAD = {preload}')
if preload != 'NOT SET':
    lib = ctypes.CDLL(preload)
    print(f'Loaded OK: {lib}')
print('PASS')
"

run_test "Test 3: numpy SGEMM (triggers OpenBLAS init)" \
$RUN python -c "
import numpy as np
print(f'numpy {np.__version__}')
a = np.random.randn(2000, 2000).astype(np.float32)
b = np.random.randn(2000, 2000).astype(np.float32)
c = a @ b
print(f'SGEMM result: shape={c.shape}, sum={c.sum():.1f}')
print('PASS')
"

run_test "Test 4: scipy BLAS" \
$RUN python -c "
import scipy.linalg
import numpy as np
a = np.random.randn(1000, 1000)
q, r = scipy.linalg.qr(a)
print(f'QR decomposition: Q={q.shape}, R={r.shape}')
print('PASS')
"

run_test "Test 5: verify numpy/faiss OpenBLAS were actually replaced" \
$RUN python -c "
import os, site, glob

# These must NOT have the old file sizes from the build log
old_sizes = {
    'libopenblas64_p': 25804257,   # numpy's old 0.3.23
    'libopenblas-r0':  10044585,   # faiss's old 0.3.15
}

replaced = 0
for sp in site.getsitepackages():
    for lib in glob.glob(os.path.join(sp, '**', 'libopenblas*.so'), recursive=True):
        if 'scipy_openblas32' in lib:
            continue
        size = os.path.getsize(lib)
        basename = os.path.basename(lib)
        print(f'  {basename}: {size} bytes')
        for key, old_size in old_sizes.items():
            if key in basename and size == old_size:
                print(f'    ERROR: still has old size — NOT replaced!')
                raise RuntimeError(f'{lib} was not replaced')
        replaced += 1

assert replaced >= 2, f'Expected >= 2 replacements, got {replaced}'
print(f'{replaced} libraries verified as replaced')
print('PASS')
"

run_test "Test 6: sklearn KMeans (the actual crash point)" \
$RUN python -c "
from sklearn.cluster import KMeans
import numpy as np
X = np.random.randn(10000, 64).astype(np.float32)
km = KMeans(n_clusters=100, n_init=1, max_iter=10, random_state=0)
km.fit(X)
print(f'KMeans: {km.n_clusters} clusters, {km.n_iter_} iterations')
print('PASS')
"

run_test "Test 7: kilosort + spikeinterface import" \
$RUN python -c "
import kilosort
import spikeinterface
print(f'kilosort {kilosort.__version__}')
print(f'spikeinterface {spikeinterface.__version__}')
print('PASS')
"

run_test "Test 8: CUDA available" \
$RUN python -c "
import torch
print(f'torch {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    t = torch.randn(1000, 1000, device='cuda')
    r = t @ t
    print(f'GPU matmul OK: {r.shape}')
print('PASS')
"

run_test "Test 9: cuFFT works (host-driver/cuFFT compatibility — the kilosort failure point)" \
$RUN python -c "
import torch
# Small + medium + kilosort-style sizes
for n in (1024, 60_000, 16_384 * 32):
    x = torch.randn(n, device='cuda')
    y = torch.fft.fft(x)
    assert y.shape == (n,)
    print(f'cuFFT OK at n={n}')
print('PASS')
"

# Cleanup handled by EXIT trap

echo ""
if [ $FAILURES -gt 0 ]; then
    echo "=== DONE with $FAILURES FAILED test(s): $(date) ==="
    echo "SIF at: $SIF_PATH (may not be reliable)"
    exit 1
else
    echo "=== All 8 tests PASSED: $(date) ==="
    echo "SIF ready at: $SIF_PATH"
fi
