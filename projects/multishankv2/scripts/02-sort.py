from pathlib import Path
import argparse
import os, sys, subprocess, ctypes, tempfile

# ── GH200 OpenBLAS fix ─────────────────────────────────────────────────
# scipy_openblas32 (bundled in scipy.libs/) segfaults on GH200 ARM nodes
# (288 cores > compile-time NUM_BUFFERS ~128). The crash occurs in
# blas_memory_alloc's auxiliary-array fallback when multiple OpenMP threads
# call SGEMM simultaneously (e.g., sklearn KMeans inside KiloSort4).
#
# Our LD_PRELOAD'd OpenBLAS 0.3.31 (built with NUM_THREADS=512) works
# fine, but scipy uses prefixed symbols (scipy_sgemm_ etc.) that
# LD_PRELOAD can't override.
#
# Fix: compile a thin shim that redirects scipy-prefixed BLAS calls to
# the standard symbols resolved from our good LD_PRELOAD'd library.
# Loaded with RTLD_GLOBAL before scipy imports so it wins symbol lookup.
_BLAS_SHIM_SRC = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#define FWD(ret,name,args,call) \
  ret scipy_##name args { \
    static ret (*f) args = 0; \
    if(!f) f = dlsym(RTLD_DEFAULT, #name); \
    if(f) return f call; \
  }
FWD(void, sgemm_, (char*a,char*b,int*m,int*n,int*k,float*al,float*A,int*la,float*B,int*lb,float*be,float*C,int*lc), (a,b,m,n,k,al,A,la,B,lb,be,C,lc))
FWD(void, dgemm_, (char*a,char*b,int*m,int*n,int*k,double*al,double*A,int*la,double*B,int*lb,double*be,double*C,int*lc), (a,b,m,n,k,al,A,la,B,lb,be,C,lc))
FWD(float, sdot_, (int*n,float*x,int*ix,float*y,int*iy), (n,x,ix,y,iy))
FWD(double, ddot_, (int*n,double*x,int*ix,double*y,int*iy), (n,x,ix,y,iy))
FWD(float, snrm2_, (int*n,float*x,int*ix), (n,x,ix))
FWD(double, dnrm2_, (int*n,double*x,int*ix), (n,x,ix))
FWD(void, sscal_, (int*n,float*a,float*x,int*ix), (n,a,x,ix))
FWD(void, dscal_, (int*n,double*a,double*x,int*ix), (n,a,x,ix))
FWD(void, saxpy_, (int*n,float*a,float*x,int*ix,float*y,int*iy), (n,a,x,ix,y,iy))
FWD(void, daxpy_, (int*n,double*a,double*x,int*ix,double*y,int*iy), (n,a,x,ix,y,iy))
'''

def _load_blas_shim():
    try:
        src = tempfile.NamedTemporaryFile(suffix='.c', mode='w', delete=False)
        src.write(_BLAS_SHIM_SRC)
        src.close()
        so = src.name.replace('.c', '.so')
        subprocess.run(
            ['gcc', '-shared', '-fPIC', '-O2', '-o', so, src.name, '-ldl'],
            check=True, capture_output=True,
        )
        ctypes.CDLL(so, mode=ctypes.RTLD_GLOBAL)
    except Exception as e:
        print(f"WARNING: BLAS shim failed ({e}), scipy_openblas32 may crash",
              file=sys.stderr, flush=True)

_load_blas_shim()
# ── End GH200 fix ──────────────────────────────────────────────────────

import spikeinterface.full as si


# Sorter-specific kwargs
SORTER_KWARGS = {
    'kilosort4':      dict(do_correction=False),
    'kilosort3':      dict(do_correction=False),
    'kilosort2_5':    dict(do_correction=False),
    'kilosort2':      dict(do_correction=False),
    'mountainsort5':  dict(detect_threshold=4.0),
    'tridesclous2':   {},
    'spykingcircus2': {},
    'lupin':          {},
    'ironclust':      {},
    'yass':           {},
}

AVAILABLE_SORTERS = list(SORTER_KWARGS.keys())


def run_sorter(sorter_name, recording, working_folder):
    sorter_key = sorter_name.lower().replace('-', '_')
    kwargs = dict(SORTER_KWARGS.get(sorter_key, {}))  # copy to avoid mutating the global
    sorter_folder = working_folder / f"sorter_{sorter_key}"

    # For any Kilosort variant, instruct it to write a binary file so the
    # raw output can be read back as an external Kilosort run if needed.
    if sorter_key.startswith('kilosort'):
        kwargs['use_binary_file'] = True

    print(f"\nSorting with {sorter_name}...")
    si.run_sorter(
        sorter_key,
        recording,
        folder=sorter_folder,
        verbose=True,
        remove_existing_folder=True,
        **kwargs,
    )
    print(f"  -> Saved to: {sorter_folder}")


def main():
    parser = argparse.ArgumentParser(
        description='Step 2: Spike sort preprocessed recording',
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument('output_folder', type=str,
                        help='Path to output folder (same as used in preprocessing)')
    parser.add_argument(
        '--sorters', '-s',
        nargs='+',
        default=['kilosort4'],
        metavar='SORTER',
        help=(
            'One or more sorters to run (space-separated).\n'
            f'Available: {", ".join(AVAILABLE_SORTERS)}\n'
            'Default: kilosort4\n'
            'Examples:\n'
            '  --sorters kilosort4\n'
            '  --sorters kilosort4 ironclust yass'
        ),
    )
    args = parser.parse_args()

    global_job_kwargs = dict(n_jobs=20, mp_context='fork', progress_bar=True)
    si.set_global_job_kwargs(**global_job_kwargs)

    working_folder = Path(args.output_folder)
    preprocessed_folder = working_folder / "preprocessed"

    if not preprocessed_folder.is_dir():
        raise FileNotFoundError(
            f"Preprocessed recording not found at: {preprocessed_folder}\n"
            "Please run 01-preprocess.py first."
        )

    print("Loading preprocessed recording...")
    recording_preprocessed = si.load(preprocessed_folder)

    print(f"Sorters to run: {args.sorters}")
    for sorter in args.sorters:
        run_sorter(sorter, recording_preprocessed, working_folder)

    print(f"\nSpike sorting complete. Results saved in: {working_folder}")


if __name__ == "__main__":
    main()
