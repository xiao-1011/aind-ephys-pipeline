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
