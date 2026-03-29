# Building ARM SIF containers on Dardel GH200 nodes

## Prerequisites

The ARM SIF must be built on a GH200 compute node (aarch64), not on the login node (x86).

## Steps

### 1. Get an interactive GH200 session

```bash
salloc -A naiss2026-3-127-gh -p gpugh -t 02:00:00 -n 1 -c 10 --gpus=1
srun --pty bash
```

### 2. Load modules

The GH200 nodes use different modules than the login nodes.

```bash
ml systemdefault/1.0.0
ml apptainer/1.4.4
```

### 3. Redirect apptainer cache to project space

The home directory quota on compute nodes is too small for container builds.

```bash
export APPTAINER_CACHEDIR=/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-cache
export APPTAINER_TMPDIR=/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-tmp
mkdir -p $APPTAINER_CACHEDIR $APPTAINER_TMPDIR
```

### 4. Build the SIF

lz4 compression is required — GH200 compute nodes do not support the default zlib.

```bash
apptainer build --mksquashfs-args "-comp lz4" \
    /cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer/kilosort4-arm.sif \
    /cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc/arm-apptainer/kilosort4-arm.def
```

Build takes ~20-30 minutes.

### 5. Clean up build cache

The build cache and tmp dirs are only needed during the build and can be safely removed.

```bash
rm -rf /cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-cache
rm -rf /cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-tmp
```

### 6. Exit the interactive session

```bash
exit
```
