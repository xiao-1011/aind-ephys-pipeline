# DREDGE-100 v3 batch: reproducible motion and postprocessing

Fresh re-sort of all raw sessions with the v2 settings (`DREDGE100_V2_BATCH.md`)
plus seeds for every random step we control. The v2 batch
`batch_runs/20261012_125513` and its archives in `session_archives/dredge100_v2/`
stay untouched.

## Changes from v2

| Change | v2 | v3 |
|---|---|---|
| Preprocessing commit (fork `xiao-1011/aind-ephys-preprocessing`) | `194532b` (tag `dmclab-1.4.0-v2`) | `939d3c4` (tag `dmclab-1.4.0-v3`) |
| `preprocessing.motion_correction.noise_levels` | absent: `compute_motion()` estimates noise from unseeded random chunks | `{"random_slices_kwargs": {"num_chunks_per_segment": 400, "chunk_duration": "500ms", "seed": 0}}`, cached before `compute_motion()` |
| `postprocessing.extensions.random_spikes.seed` | `null` | `0` |
| `postprocessing.extensions.noise_levels.random_slices_kwargs.seed` | `null` | `0` |
| Schema | no `motion_correction.noise_levels` | allows it (seed required) |

Everything else is identical: containers (pipeline-base 1.4.0, KS4 arm64,
SI #4830 curation image), DREDGE-100 motion settings, KS4 settings, metrics,
QC thresholds, UnitRefine/Bombcell configuration.

400 chunks of 0.5 s comes from the noise-chunk pilot
(`maintenance/noise_chunks_3sessions_20261020_135231`, 3 sessions, 12 shanks).
No count passed the accuracy gate (noise error vs the full-recording reference
and peak recall/precision) on every shank: 20 chunks passed 0/12, 400 passed
9/12, 800 and 1600 passed 11/12. All failures are in the low-yield session
vr1520260319_g0. 400 was kept because 800 did not improve seed-to-seed sorting
stability enough to meet the pilot's rule (unit agreement 0.746 vs 0.748;
QC-SUA found by both seeds 0.917 vs 0.915). A fixed seed makes the estimate
repeatable; it does not make it closer to the full-recording noise.

## What is and is not reproducible

Repeat test (two runs, `batch_runs/20261022_160539` and `20261022_172242`, of
vr15 and vr23, 8 shanks). The run folders and their archives have since been
deleted; the comparison results are kept in
`maintenance/v3_reprotest_compare_20261026`:

- Motion, motion peaks and the corrected preprocessed binary: bit-identical on all shanks.
- Postprocessing and curation labels: identical whenever the sorting is identical,
  except `sd_ratio` (SpikeInterface draws its noise chunks unseeded, no parameter
  to seed them; not used by QC, Bombcell or UnitRefine).
- Kilosort4 on GPU: not bit-reproducible from identical input. 6/8 shanks gave
  identical sortings; vr23 group1 (215 vs 216 units) and group3 (23 of 195 units
  changed) did not. Bombcell/UnitRefine labels of a few unchanged neighbouring
  units can then change too (PCA-based metrics). Accepted for v3.

## Known caveat

UnitRefine models are still downloaded from the Hugging Face Hub at run time
without a pinned revision.

## Full batch

The two repeat-test runs were the pilot. Their archives
(`session_archives/dredge100_v3_reprotest_{a,b}`, since deleted) were not
reused; all sessions were sorted fresh. From a clean `main` on Arrhenius:

```bash
U=/nobackup/proj/disk/dmclab/personal/$USER
cd "$U/git_repo/aind-ephys-pipeline" && git switch main
bash scripts/start_arrhenius_batch.sh dredge100_v3
```

Do not change `pipeline/active_params.json` during the batch. Any change requires
a new archive root.
