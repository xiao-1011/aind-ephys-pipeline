# Working with Dardel HPC

## Login

```bash
ssh xiao1011@dardel.pdc.kth.se
```

## Environment Setup

```bash
ml PDC/24.11
ml miniconda3/25.3.1-1-cpeGNU-24.11
ml apptainer/1.4.0-cpeGNU-24.11
```

## File Transfer

### Download

```bash
rsync -ah --progress xiao1011@dardel-ftn01.pdc.kth.se:/cfs/klemming/projects/supr/dmclab/nextflow_results/vr1220251126_g1 /mnt/smb/dmclab/Xiao/pdc/dmclab/nextflow_results/
```

### Upload

```bash
rsync -ah --progress /mnt/smb/dmclab/Xiao/acc_project/npx_dataset/SGL_DATA/20260318 xiao1011@dardel-ftn01.pdc.kth.se:/cfs/klemming/projects/supr/dmclab/xiao/SGL_DATA/
```

## Interactive Session

```bash
salloc -A naiss2026-3-127-gh -p gpugh -t 02:00:00 -n 1 -c 10 --gpus=1
srun --pty bash
```

## Terminate Task

```bash
scancel -u $USER
```

## Check Usage

```bash
sacct -u $USER --format=JobID,Elapsed,AllocCPUS,State
squeue -p gpugh -o "%.10i %.8u %.12j %.8T %.10M %.10l %.6C %P %R"
squeue -p gpugh -u $USER
```
