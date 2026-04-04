# pfcv2 TODO

## Preprocessing order fix

`01-preprocess.py` currently applies CMR **before** bad channel detection:

```
phase_shift → CMR → bandpass → bad_channel_detect
```

This is suboptimal — dead/noisy channels contaminate the CMR median, spreading artifacts to all good channels. The correct order (used in `projects/multishank/`) is:

```
phase_shift → bandpass → bad_channel_detect → CMR
```

Applying this fix will invalidate the PREPROCESS cache and require a full pipeline re-run.

## Step numbers in Nextflow process names

Add step numbers to process names (e.g., `PREPROCESS` → `S01_PREPROCESS`) for clearer SLURM job identification. Deferred because renaming processes invalidates all Nextflow caches.

## Multi-GPU KS4: run multiple sorts per GPU node

The `gpu` partition is `OverSubscribe=EXCLUSIVE` — every KS4 job gets a full node (4 GPUs) even though we only use 1. For multishank, we run 4 shank sorts as 4 separate jobs = 4 node-hours, but could run them as 1 job on 4 GPUs = 1 node-hour (4x savings).

Options:
- Single SLURM job that launches 4 `CUDA_VISIBLE_DEVICES=N` processes in parallel
- Or a wrapper script in Nextflow that packs multiple sorts onto one node

Also applies to pfcv2 batch: when processing multiple probes, KS4 jobs from different probes could share a GPU node.

Blocked on: confirming with PDC support that running multiple processes on an exclusive GPU node is acceptable.
