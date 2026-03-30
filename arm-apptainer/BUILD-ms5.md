# Building MountainSort5 CPU SIF on Dardel login node

## Prerequisites

This is an x86_64 container — build on a **login node**, NOT a GH200 compute node.

## Steps

### 1. Load modules

```bash
ml PDC/24.11
ml apptainer/1.4.0-cpeGNU-24.11
```

### 2. Redirect apptainer cache to project space

```bash
export APPTAINER_CACHEDIR=/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-cache
export APPTAINER_TMPDIR=/cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-tmp
mkdir -p $APPTAINER_CACHEDIR $APPTAINER_TMPDIR
```

### 3. Build the SIF

```bash
apptainer build \
    /cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer/mountainsort5-cpu.sif \
    /cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc/arm-apptainer/mountainsort5-cpu.def
```

Build takes ~5-10 minutes (pulls base image + pip install mountainsort5).

### 4. Clean up build cache

```bash
rm -rf /cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-cache
rm -rf /cfs/klemming/projects/supr/dmclab/ephys-pipeline-cache/apptainer-build-tmp
```
