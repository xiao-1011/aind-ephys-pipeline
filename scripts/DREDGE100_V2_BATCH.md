# DREDGE-100 v2 batch: fresh sort with repaired metrics

Fresh re-sort of all raw sessions with the policy chosen in
`MOTION_POLICY_REVIEW.md`: DREDGE-100 motion correction in preprocessing,
KS4 internal correction off, and the DREDGE-corrected recording as analyzer input.
The archived batch `batch_runs/20261006_180017` (35 sessions) stays untouched as
the historical record. Its archives were written to `session_archives/cohort*/` and
moved unchanged to `session_archives/dredge100_v1/cohort*/` on 2026-10-14; its
manifest and reports still show the old paths (see the README in that folder).

## Changes from the archived batch

Archived run: commit `4f5331a` plus the KS4 BLAS-thread config patch
(now commit `8b4f470`). Everything not listed below is identical: raw
sessions, containers, preprocessing, DREDGE-100 motion settings, KS4 settings,
default QC thresholds, UnitRefine/Bombcell configuration.

| Change | Archived | v2 |
|---|---|---|
| `quality_metrics.metric_params.snr` | `peak_sign`, `peak_mode` (rejected by SI 0.105, so SNR is all NaN) | `method: "extremum"` |
| `quality_metrics.metric_params.sd_ratio` | Includes `peak_sign: "neg"` (all NaN) | `peak_sign` removed |
| Schema | `snr` only allowed legacy keys | Also allows `method` |
| Curation image | Stock pipeline-base (one session recovered with backport) | SI #4830 backport for every session, checksum-verified at batch start and resume; its `.sha256`/provenance packed into every archive |
| Empty-metric guard | None | Archiving fails if any quality-metric column has no finite value across all shanks of a session |
| Batch start | Any working tree | Refuses tracked changes against HEAD; `--session` selects pilot sessions |

Consequences: SNR and SD-ratio get values, so UnitRefine and Bombcell (MUA rule
`snr > 5`) labels change. KS4 is not bit-reproducible, so units and spike times
differ slightly from the archive. Default QC does not use SNR/SD-ratio.

## Known caveat

The curation capsule downloads the UnitRefine models from the Hugging Face Hub at
run time, without a pinned revision. Check the logged revisions match between
the pilot and the full batch (`model_provenance.json` in the trace replay records
the revisions used for the policy review).

## 1. Pilot: two sessions

vr15 (well-behaved) and vr23 (irregular motion, weak groups 0/1). Run from a
clean `main` on Arrhenius:

```bash
U=/nobackup/proj/disk/dmclab/personal/$USER
cd "$U/git_repo/aind-ephys-pipeline" && git switch main && git pull --ff-only
python3 scripts/arrhenius_batch.py start --user-root "$U" \
  --archive-root "$U/session_archives/dredge100_v2" \
  --session cohort06/20260318/vr1520260318_g0 \
  --session cohort08/20260721/vr2320260721_g0
```

Pass criteria before the full batch:

- Both sessions `complete` with restore-verified archives (the empty-metric
  guard ran during archiving).
- Preprocessing motion present for every shank, no KS4 motion folder, and the
  analyzer recording is the corrected binary (enforced by `archive_session.py`).
- Motion traces close to the archived ones for the same sessions.
- Per-shank unit and QC-pass counts similar to the archive; QC-SUA roughly
  vr15 212 and vr23 31 (valid-SNR recheck in `MOTION_POLICY_REVIEW.md`).
- No failed or retried tasks other than expected resource retries; note the
  runtime to size the full batch.

## 2. Full batch

Same commit and parameters as the pilot (the batch checks the parameter hash of
each pilot archive), reusing the two verified pilot archives:

```bash
P="$U/batch_runs/<pilot batch>"
python3 scripts/arrhenius_batch.py start --user-root "$U" \
  --archive-root "$U/session_archives/dredge100_v2" \
  --pilot-report "$P/reports/vr1520260318_g0.json" \
  --pilot-report "$P/reports/vr2320260721_g0.json"
```

Do not change `pipeline/active_params.json` between the pilot and the full
batch. Any change requires a new archive root and a new pilot.
