# Alternative fixes for KS4 ARM container issues

## Proper fix: build scipy-prefixed OpenBLAS with NUM_THREADS=512

The current runtime workaround (BLAS shim in 02-sort.py) compiles a small
C wrapper at startup that redirects `scipy_sgemm_` etc. to our good
LD_PRELOAD'd OpenBLAS. This works but adds startup overhead and fragility.

The proper container-level fix: build OpenBLAS 0.3.31 with
`SYMBOLPREFIX=scipy_` and `NUM_THREADS=512`, then replace scipy's bundled
`libscipy_openblas-c5a9b014.so` with it. This eliminates the buggy
auxiliary-array buffer path entirely.

### Root cause

scipy_openblas32 (from PyPI) is compiled with NUM_THREADS ~128. On GH200
nodes (288 cores, with SLURM potentially assigning CPU numbers >= 128),
OpenBLAS's `blas_memory_alloc` uses an auxiliary-array fallback that has a
bug causing segfaults in `sgemm_incopy` when multiple OpenMP threads call
SGEMM simultaneously (e.g., sklearn KMeans inside KiloSort4).

### Where to add it

In kilosort4-arm.def `%post`, add a third build variant in Part B
(after the ILP64 build), and a third replacement step in Part C:

```bash
    # Build 3: LP64 with scipy_ symbol prefix — for scipy
    echo "=== Building scipy-prefixed LP64 variant ==="
    make clean 2>&1 | tail -1
    make -j$(nproc) NUM_THREADS=512 USE_OPENMP=0 SYMBOLPREFIX=scipy_ $FFLAGS 2>&1 | tail -5
    cp -v $(find . -maxdepth 1 -name 'libopenblas*.so' -not -type l | head -1) /tmp/libopenblas_scipy.so
```

Then in the Part C Python replacement script, add:

```python
    scipy_lib = '/tmp/libopenblas_scipy.so'
    for sp in site.getsitepackages():
        for lib in glob.glob(os.path.join(sp, '**', 'libscipy_openblas*.so'), recursive=True):
            if '/scipy_openblas32/' in lib:
                continue
            print(f'  [scipy-prefix] {lib}')
            print(f'    old: {os.path.getsize(lib)} bytes')
            shutil.copy2(scipy_lib, lib)
            print(f'    new: {os.path.getsize(lib)} bytes')
```

### Once applied

Remove the BLAS shim from `projects/pfcv2/scripts/02-sort.py` (the
`_BLAS_SHIM_SRC` / `_load_blas_shim()` block). Also remove Part A
(the scipy_openblas32 replacement) since this new build replaces it.
