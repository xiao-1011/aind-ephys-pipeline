# Alternative fixes for KS4 ARM container issues

## If Part D (ldd scan) stops working

The current approach (Part D in kilosort4-arm.def) scans scipy's Fortran
extensions with `ldd` to find missing shared libs (e.g., libgfortran) and
copies the system equivalent into scipy.libs/.

If this breaks, here's a simpler alternative: force-reinstall scipy from
PyPI to get a complete manylinux wheel that bundles all its shared libs.

### Where to add it

In kilosort4-arm.def `%post`, right after the main `pip install` block
(after `aind-log-utils==0.2.3`), BEFORE the OpenBLAS fix sections:

```bash
    # Force-reinstall scipy from PyPI to get a complete manylinux wheel.
    # The NGC base image's pre-installed scipy may be missing bundled shared
    # libs (e.g., libgfortran) in scipy.libs/ — the PyPI wheel includes them.
    SCIPY_VER=$(python -c "import scipy; print(scipy.__version__)")
    echo "=== Reinstalling scipy ${SCIPY_VER} from PyPI (complete wheel) ==="
    pip install --no-cache-dir --force-reinstall --no-deps "scipy==${SCIPY_VER}"
```

### Why it works

- `--force-reinstall` downloads a fresh manylinux_2_17_aarch64 wheel from PyPI
- That wheel bundles libgfortran, libgcc_s, libscipy_openblas in scipy.libs/
- `--no-deps` prevents cascading reinstalls of other packages
- Pinning `scipy==${SCIPY_VER}` keeps the exact same version
- Part A then replaces the wheel's OpenBLAS with our good copy as usual

### If using this, Part D can be removed

The force-reinstall makes Part D redundant since scipy.libs/ will be
complete from the wheel.
