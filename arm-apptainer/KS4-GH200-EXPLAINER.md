# KiloSort4 on GH200: Why it breaks and how we fixed it

Dardel's GPU partition (`gpugh`) uses NVIDIA GH200 Grace Hopper nodes.
The Grace CPU is **ARM64 (aarch64)** with **288 hardware threads** — two
properties that together break the entire Python scientific stack out of
the box.

This document explains the problem and the fix, at two levels.

---

## Plain-language summary

Dardel's GPU nodes have a special chip (GH200 Grace Hopper) that uses ARM
instead of Intel.  The math libraries bundled inside Python (OpenBLAS)
were compiled for Intel and assume at most ~128 CPU cores.  When they
detect 288 cores on GH200, they try to allocate a buffer that doesn't
exist and crash.

The fix has two parts:

1. **At container build time** (`kilosort4-arm.def`): we find all 4 copies
   of the broken math library inside the container and replace each one
   with a version we compile from source, telling it "expect up to 512
   cores".

2. **At script runtime** (`02-sort.py`, the BLAS shim): scipy calls its
   math functions by custom names (`scipy_sgemm_` instead of `sgemm_`), so
   our replacement library can't intercept them via `LD_PRELOAD`.  The
   sorting script compiles a tiny C "translator" at startup that
   redirects `scipy_sgemm_` → `sgemm_` from the good library.

---

## Technical detail

### Root cause: OpenBLAS `NUM_THREADS` overflow

OpenBLAS allocates a fixed-size array of thread-local buffers at init
time.  The array size is set at **compile time** via `NUM_THREADS`
(default ~128, varies by version).  At runtime, OpenBLAS detects the CPU
core count and tries to use that many slots.  On GH200 (288 threads),
slot 129+ doesn't exist → segfault inside `blas_memory_alloc`.

This kills anything that touches BLAS: `numpy` matmul, `scipy.linalg`,
`sklearn.cluster.KMeans` (which KiloSort4 uses internally).

### Why there are four broken copies

The PyTorch base image (`nvcr.io/nvidia/pytorch:26.02-py3`) plus `pip
install` pulls in **four** separate OpenBLAS shared libraries:

| # | Location | Interface | Used by |
|---|----------|-----------|---------|
| 1 | `scipy.libs/libscipy_openblas*.so` | LP64, prefixed symbols (`scipy_sgemm_`) | scipy |
| 2 | `numpy.libs/libopenblas64_p*.so` | ILP64 (64-bit integers) | numpy |
| 3 | `faiss_cpu.libs/libopenblas*.so` | LP64 (32-bit integers) | FAISS |
| 4 | `scipy_openblas32/lib/libscipy_openblas.so` | LP64, prefixed | pip package (already 0.3.31, works) |

Libraries 1–3 are old versions (<0.3.28) and all crash on GH200.
Library 4 is fine but only scipy's pip package uses it.

### Container fix: `kilosort4-arm.def`

The `%post` section does four things:

**Part A** — Replace scipy's prefixed OpenBLAS (`#1`) with the working
copy from `scipy_openblas32` (`#4`).  Same symbol prefix, newer version.

**Part B** — Download OpenBLAS 0.3.31 source and build it twice:
- LP64 variant (32-bit integer BLAS) with `NUM_THREADS=512`
- ILP64 variant (64-bit integer BLAS) with `NUM_THREADS=512`

**Part C** — Walk every `*.libs/` directory in site-packages and replace
each bundled `libopenblas*.so` with the matching freshly-built variant
(LP64 or ILP64, determined by whether `64` appears in the filename).

**Part D** — Fix missing Fortran shared-library dependencies.  The
replaced `.so` files originally had auditwheel-hashed companion libs
(e.g. `libgfortran-daac5196.so.5.0.0`) that may not match the new build.
A Python script runs `ldd` on scipy's Fortran extensions, finds "not
found" deps, and copies the system equivalents into `scipy.libs/`.

The `%environment` section sets two safety nets:
- `LD_PRELOAD=/usr/local/lib/libopenblas.so` — the source-built LP64
  library takes precedence for any standard BLAS calls not resolved via
  RPATH.
- `OPENBLAS_NUM_THREADS=64` — caps the thread count to avoid allocating
  288 thread-local buffers (diminishing returns past ~64 anyway).

### Runtime fix: BLAS shim in `02-sort.py`

Even after fixing the container, scipy still calls **prefixed** symbols
(`scipy_sgemm_` instead of `sgemm_`).  The `LD_PRELOAD`'d library only
exports standard names, so it can't intercept those calls.

The shim (lines 18–54 of `02-sort.py`) runs before any `import scipy`:

1. Writes a small C source that defines `scipy_sgemm_()` as a function
   that does `dlsym(RTLD_DEFAULT, "sgemm_")` and forwards the call.
   Same for 8 other BLAS routines (dgemm, sdot, ddot, snrm2, dnrm2,
   sscal, dscal, saxpy, daxpy).
2. Compiles it with `gcc -shared -fPIC` into a temporary `.so`.
3. Loads it with `ctypes.CDLL(..., mode=RTLD_GLOBAL)` so it wins symbol
   lookup before scipy's bundled library.

This is a belt-and-suspenders approach: Part A of the container fix
should have already replaced scipy's bundled library, but the shim
catches any edge cases where the old prefixed symbols survive (e.g.
cached `.pyc` files, different scipy rebuild paths).

### Custom apptainer binary

Dardel's system `apptainer` on the login/CPU nodes is x86.  The GH200
GPU nodes need an ARM-native binary.  The `nextflow.config` SORT_KS4
block uses `beforeScript` to inject a pre-built apptainer into `PATH`:

```groovy
beforeScript = """
    chmod +x ${params.apptainer_bin_dir}/apptainer
    export PATH=${params.apptainer_bin_dir}:\$PATH
"""
```

### Build verification

`build-ks4.sh` runs 8 post-build tests covering:
1. Environment variables (`OPENBLAS_NUM_THREADS`, `LD_PRELOAD`)
2. numpy SGEMM (2000×2000 matmul — triggers OpenBLAS init)
3. scipy QR decomposition
4. File-size check that bundled `.so` files were actually replaced
5. sklearn KMeans on 10k×64 data (the exact crash point in KS4)
6. KiloSort + SpikeInterface import
7. CUDA availability and GPU matmul

### File reference

| File | Purpose |
|------|---------|
| `kilosort4-arm.def` | Container definition (OpenBLAS replacement) |
| `build-ks4.sh` | SLURM batch build + 8 verification tests |
| `../projects/pfcv2/scripts/02-sort.py` | Runtime BLAS shim (lines 18–54) |
| `../projects/pfcv2/nextflow.config` | Custom apptainer injection (SORT_KS4 `beforeScript`) |
