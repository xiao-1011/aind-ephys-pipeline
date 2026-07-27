# PFC Pipeline Operations Log

Chronological record of significant actions on the PFC pipeline:
batch submissions, Dardel infrastructure fixes, transfers (KI↔Dardel),
storage cleanups, and pipeline-code changes that affected behavior.

Goal: a future person should be able to skim this and understand what
was done, when, and roughly why — without spelunking through git log.

## Conventions

- **Newest at top.** Add new entries at the top under today's date.
- Bracketed actor: `[Anil]` (you) or `[Claude]` (assistant) or `[PDC]` (Dardel admin / system event).
- Be terse. One line per action where possible. Reference job IDs, paths,
  commit hashes when they help.
- Group related actions under one date heading.

## Quick reference

- KI raw:      `/mnt/dmclab/Joana/PFC-Str_behavior_project/Recordings/Raw_data/<animal>/<sid>`
- KI results:  `/mnt/dmclab/Joana/PFC-Str_behavior_project/Analysis/ephys-pipeline-output/results/<sid>`
- Dardel raw:  `/cfs/klemming/projects/supr/dmclab/Joana/Raw_data/<animal>/<sid>`
- Dardel out:  `/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/<batch>/results/<sid>`
- Batch staging: `/cfs/klemming/projects/supr/dmclab/Joana/ephys_batch<N>/` (symlinks)
- Project storage: `naiss2026-3-127`, quota 29.30 TiB (PI Konstantinos Meletis)

---

## 2026-07-06
- [Claude] Batch7 orchestrator (job 22009658) COMPLETED cleanly in 1d10h. 21/24 sessions fully done. **3 failures, all on 1061234**: (1) `PREPROCESS 1061234_day2_g0_imec0` TIMED OUT at 1h51m (SLURM SIGTERM, exit 140), left day2 with only imec1 in results; (2) `SORT_KS4_BATCH [1061234_day3+day4]` (job 22013115) hit cuFFT_INTERNAL_ERROR at 1m44s on nid002897 — same back-to-back-tenancy pattern as before, but this time `sleep 60` was not enough (60s sleep + 44s KS4 = 104s). None of the failures are allocation/fairshare related — those only affect queue wait time, not job execution.
- [Claude] **Bumped cuFFT race guard**: `main.nf` SORT_KS4_BATCH: `sleep 60 → 120`, plus added `nvidia-smi > /dev/null` warmup after the sleep to force GPU/CUDA context init before the 4 parallel Python processes hit cuFFT. Mirrored to Dardel.
- [Claude] Narrowed batch7 staging to only the 3 broken sessions (1061234_day2/day3/day4) — moved 21 successful ones from `ephys_batch7/` → `ephys_batch7_done/`. Submitted retry as **job 22070436** (reason `Priority`, normal queue). Fresh run of just these 3 sessions with the new fixes in place (KS4 sleep 120 + nvidia-smi warmup, PREPROCESS 2× duration + retry). Only "waste" is 1061234_day2_imec1 reprocessed (succeeded first time, will produce identical output). ~4-6h expected wall clock, avoids the ~24h full-batch7 -resume cost from PREPROCESS cache invalidation.
- [Claude] **PREPROCESS time bump + retry pattern**: `nextflow.config` PREPROCESS: `time = 1× duration_minutes, min 30m` → `attempt1: 2× duration_minutes, min 60m; attempt2: 1440m` with `errorStrategy = 'retry'` on timeout codes 124-140 and `maxRetries = 1`. Same pattern as SORT_TDC2 / ANALYZE_KS4. Note: bumping attempt-1 formula invalidates the cache hash for all previously-completed PREPROCESS tasks — on batch7 `-resume` all 48 PREPROCESS will re-run (plus everything downstream). Cost is acceptable since PREPROCESS is ~1h each and this is a one-time hit.

## 2026-07-27
- [Claude] Prepared **batch8 (FINAL)**: 5 pending animals (1053836/1060141/1060359/1020228/1033998) + 986168 partial closeout. Staged `Joana/ephys_batch8/` with 15 symlinks for the 5 already-uploaded animals (0 broken). Cloned `slurm_submit_batch7.sh` → `slurm_submit_batch8.sh` on both workstation and Dardel. Started 986168 raw upload from workstation (tmux `rsync_986168`, ~981 GB total, ~3h). Will add symlinks for 986168_day1/day3/day4 (skipping day2 which is already fully done on KI) once raw arrives — total staging will be 18 sessions.
- Batch8 spec: 5 animals + 3 sessions from 986168 = 18 sessions. After batch8 rsync-to-KI: **30/30 animals fully processed on KI** — pipeline officially finished for Joana.

## 2026-07-03
- [Claude] Prepared batch7: staged `Joana/ephys_batch7/` with 24 valid symlinks (6 animals × 4 days: 1053835, 1060148, 1060358, 1061220, 1061233, 1061234). Cloned `slurm_submit_batch6.sh` → `slurm_submit_batch7.sh` (workstation + Dardel). Wall time restored to `3-12:00:00` (maintenance done). Ready to submit: `cd /cfs/klemming/projects/supr/dmclab/aind-ephys-pipeline-pfc/projects/pfcv3 && sbatch slurm_submit_batch7.sh`.
- [Claude] Batch6 partial cleanup: byte-verified 5 raws (1021218, 1031913, 1053833, 1060138, 1060360) as KI=Dardel identical, then deleted them. Also deleted `pfcv3-batch6/work/` (all) and 19 non-1033996 session dirs under `pfcv3-batch6/results/`. **Kept: 1033996 raw + 1033996_day1-4 results.** Storage 23.58 TiB (80%) → 12.62 TiB (43%), freed ~11 TB. Batch7 will fit comfortably. All 6 deletes logged via `log_dardel_event.sh` to `PFC_DARDEL_TIMELINE.csv`.

## 2026-07-02
- [Anil] Dardel back up after 2026-06-29 → 07-05 CPE / OS maintenance (partial reopen at 07-02).
- [Claude] Container smoke test on `gpugh` partition passed: KS4 SIF loads, torch+CUDA+cuFFT work on GH200 (driver 580.173.02, CUDA 13.0), Kilosort 4.0.38 loads. FFT at N=65536, 262144, 524288 all OK. CPU SIF is x86-only — only relevant on shared partition where it works fine (spikeinterface 0.103.0 imports).
- [Claude] Post-maintenance module names: compute nodes (both x86 shared and ARM gpugh) still expose the pre-maintenance modules (`PDC/24.11`, `apptainer/1.4.0-cpeGNU-24.11`, `miniconda3/25.3.1-1-cpeGNU-24.11`), so submit scripts DO NOT need module bumps. Login node offers `PDC/26.03` etc. but that would break on compute nodes. Wrapper `pipeline/bin_gh200/apptainer` hardcodes `/pdc/software/eb/software/apptainer/1.4.4/bin/apptainer` which still exists on ARM compute nodes — verified.
- [Claude] Set up 2026-07-02 batch7 tracking infrastructure:
  1. Added `Analysis/PFC_DARDEL_TIMELINE.csv` — append-only event log (columns: `date,action,scope,animal,batch,notes`; action = uploaded|deleted|processed|synced_to_ki). Backfilled from this OPERATIONS_LOG.
  2. Extended `pfcv3_status.sh` — session-level CSV now has two extra columns: `dardel_raw_upload_date` (from dir mtime on Dardel) and `dardel_raw_last_delete_date` (from latest 'deleted' event in the timeline CSV for that animal).
  3. Added `projects/pfcv3/log_dardel_event.sh` — tiny helper to safely append rows: `log_dardel_event.sh <action> <scope> <animal|-> <batch|-> "notes"`. Use it every time we rsync or rm anything in Joana/Raw_data or ephys-pipeline-output.
- [Claude] Eligible batch7 candidates (already on Dardel, awaiting processing): 1053835, 1060148, 1060358, 1061220, 1061233, 1061234 — 6 animals, ~7.5 TB raw. Plus 999770_day1 (single day for a MIXED animal) is on KI but not on Dardel. No newly-4-days-complete animals since 2026-06-26.
- [Claude] Delete candidates on Dardel (not deleted yet — user holding): batch6 raw for 1021218, 1031913, 1033996, 1053833, 1060138, 1060360 (~6.5 TB); and `pfcv3-batch6/` results dir (~6.3 TB) — all 23 sessions verified byte-perfect on KI with KS4=2/TDC2=2/cons=2. Storage 23.58 TiB (80%) → ~11 TiB (~38%) after cleanup.

## 2026-06-26
- [Claude] Batch6 retry #3 (job 21762094) — both stubborn sessions (1031913_day3, 1033996_day1) completed clean (KS4=2/TDC2=2/cons=2/warn=0). Theory confirmed: KS4_BATCH job 21762120 ran for 1h05m on nid002893 with no back-to-back tenancy.
- [Claude] **Implemented Option-1 fix for the cuFFT race**: added `sleep 60` at the start of `SORT_KS4_BATCH` script in `projects/pfcv3/main.nf`, before the 4 parallel KS4 launches, with a comment explaining the root cause. Cost: ~60s per KS4_BATCH job. Patched on workstation + mirrored to Dardel repo via Python sed. Applies to all future KS4 batches; no in-flight job affected (none running). Not propagated yet to pfcv2/multishankv2 mains (those use the same pattern but aren't in active rotation).
- **[Claude] ROOT CAUSE of cuFFT_INTERNAL_ERROR on KS4 retries — IDENTIFIED.** From `sacct`: every failed KS4_BATCH job started **within 3–7 seconds** of a previous KS4_BATCH job ending on the SAME GH200 node, and died at 41–42s wall time (= cold start + first FFT call). Every successful job either started fresh on a node or ran for hours. Same node (nid002891, nid002897, nid002893) both fails AND succeeds at different times — proving it's not a bad-node issue. **It's a race condition in the GH200 GPU / cuFFT teardown-then-init sequence**: when SLURM hands the GPU to a new tenant within seconds, the previous tenant's CUDA context / cuFFT plan-cache hasn't drained, and the new container's first FFT call hits the stale state. Fix options (cheapest first): (1) `sleep 60` at start of `SORT_KS4_BATCH`, (2) explicit `torch.cuda.empty_cache()` + `cuda.synchronize()` in 02-sort.py, (3) `#SBATCH --exclusive` on KS4 to prevent same-node back-to-back tenancy. **No code change yet** — first see if retry #3 lands on a clean node by chance.
- [Claude] Submitted batch6 3rd KS4 retry as **job 21762094**. Narrowed staging to only the 2 stubborn sessions (1031913_day3 + 1033996_day1) by moving 1031913_day1/day2 to `ephys_batch6_done/` (those 2 got fixed in retry #2). Shortened wall time `3-12:00` → `1-12:00` because cluster maintenance starts Mon 2026-06-29 and `Reserved for maintenance` blocked the 3.5d submit. Job 21762064 cancelled before that bump. Same KS4_BATCH grouping as before; hoping for different GPU node assignment to break the cuFFT determinism.
- [Claude] Started new rsync (tmux `rsync_more_animals`, log `/tmp/rsync_more_animals.log`) for 5 animals: 1061233 (resume from 318 GB partial), 1061234, 1060148, 1053835, 1060358. ~6 TB total. Fits in 11.4 TB headroom after cleanup. 1061220 already complete on Dardel (mtimes Jun 5/12 — uploaded previously, byte-perfect KI match), so excluded from this rsync.
- [Claude] Freed ~11.4 TB on Dardel by deleting raw of 11 pre-batch6 already-done animals (1020227, 1021219, 1031912, 1033993, 1033999, 1038513, 986167, 986168, 986170, 986171, 986235). All 11 verified KI=Dardel byte-for-byte before delete (file counts + total bytes identical). Storage went 29.30/29.30 TiB (100%) → 17.94/29.30 TiB (61%). `df` lagged showing 100%; `projinfo` showed the real 61%.
- [Claude] Discovered Dardel storage HIT QUOTA (29.30/29.30 TiB) — the 1061233+1061220 rsync died at 51% through 1061233 with `error in file IO (code 11)`. Job 21722964 finished at 01:51 AM successfully before the squeeze. Tmux session `rsync_61233_61220` died with it.
- [Claude] Batch6 KS4 retry result: 2 of 4 broken sessions fixed (1031913_day1, 1031913_day2). The OTHER 2 in the same KS4_BATCH (1031913_day3 + 1033996_day1) failed again with cuFFT_INTERNAL_ERROR. Same batch, same node-affinity pattern. Need a third retry — likely split that batch into single-session KS4 jobs, or pin to a different GPU node, to break the determinism.

## 2026-06-25 (evening)
- [Anil] from dmc-spikeinterfae
rsync -aL --partial --append-verify --info=progress2 --bwlimit=30M \
    --exclude='nextflow/' --exclude='*.tmp' \
    -e "ssh -c aes128-gcm@openssh.com -o Compression=no" \
    dardelcopy:/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/pfcv3-batch6/results/ \
    /mnt/smb/dmclab/Joana/PFC-Str_behavior_project/Analysis/ephys-pipeline-output/results/


- [Claude] Started rsync of next batch raw (1061233 + 1061220, 2.5 TB total) from **this workstation** to Dardel (not dmc-spike this time) via tmux session `rsync_61233_61220`. Log: `/tmp/rsync_61233_61220.log`. ~24h wall at 30 MB/s. 1061234 (3 days) and 1060148 (2 days) skipped — not 4 days yet. Post-upload Dardel will be ~24/29.3 TiB (~82%); must free batch6 results before next processing batch.
```
rsync -av --partial --info=progress2 --bwlimit=30M \
    -e "ssh -c aes128-gcm@openssh.com -o Compression=no" \
    /mnt/dmclab/Joana/PFC-Str_behavior_project/Recordings/Raw_data/1061233 \
    /mnt/dmclab/Joana/PFC-Str_behavior_project/Recordings/Raw_data/1061220 \
    dardelcopy:/cfs/klemming/projects/supr/dmclab/Joana/Raw_data/
```
- [Claude] Cancelled 21722815 (also cancelled 2 orphan GPU jobs 21722829/30 that survived orchestrator SIGKILL). Moved 19 successful sessions out of `ephys_batch6/` → `ephys_batch6_done/`, leaving only the 4 broken (1031913_day1/2/3 + 1033996_day1) in staging. Resubmitted as **job 21722964** — same script (with `-resume`), but now Nextflow only schedules ~46 tasks for the 4 broken sessions (cache-hits PREPROCESS/SORT_TDC2/ANALYZE_TDC2 for these 4). After completion: restore the 19 symlinks from `ephys_batch6_done/` for future status scans.
- [Claude] Resubmitted batch6 with `-resume` (job 21722815) to retry the 2 KS4_BATCH tasks that hit `cuFFT_INTERNAL_ERROR` on GH200. Reason: `Priority` (normal queue).
- **CAVEAT** observed on this resume: ALL 92 ADVANCED_CURATE tasks re-ran, not just downstream of the failed KS4 batches. Root cause: ADVANCED_CURATE has `path(analyzer_dir)` as BOTH input AND output — `07-advanced-curate.py` writes bombcell/unitrefine/passing_qc JSONs into the analyzer dir, mutating its hash. On `-resume` Nextflow re-hashes the (now-mutated) analyzer_dir and sees it differs from the original cached input hash → cache miss → re-run. COMPARE/COMPARE_CLEAN/CONSENSUS_DELTA cascade for the same reason. Cost: ~46 corehours, ~2.5h wall on 20 parallel slots — small but wasteful. Outputs deterministic (idempotent), so it's not incorrect, just redundant. Future fix: refactor ADVANCED_CURATE to publish JSONs separately rather than mutate the analyzer_dir.
- [Claude] Batch6 job 21710205 COMPLETED in 8h23m, but 4 sessions had KS4 fail (cuFFT_INTERNAL_ERROR on GH200): all 3 days of 1031913 + 1033996_day1. TDC2 ran fine for all. Other 19/23 sessions fully complete (KS4=2 + TDC2=2 + consensus=2, no WARNINGs).

## 2026-06-25
- [Claude] Submitted batch6 (job 21710205). 23 sessions: 1021218 (4d) + 1031913 (3d) + 1033996 (4d) + 1053833 (4d) + 1060138 (4d) + 1060360 (4d). Shortened orchestrator `-t` from `7-00:00:00` → `3-12:00:00` so it fits before the 2026-06-29 cluster maintenance window — a prior submit (job 21710199) was blocked by `Reserved for maintenance`; the shorter wall time changed reason to `Priority` (normal queue). Cancelled 21710199. Will resubmit with `-resume` after maintenance to finish whatever doesn't complete in 3.5 days.
- [Claude] Storage check before submit: 21.5/29.3 TiB used (73%), 7.9 TiB free; batch6 raw is 6.5 TB on Dardel. Removed broken symlink `ephys_batch6/1031913_day4_g0` (animal has only 3 days on KI raw); staging now has 23 valid symlinks.

## 2026-06-22
- [Claude] Extended `pfcv3_status.sh` to emit a probe-level companion CSV (`PFC_STATUS_probes.csv`) alongside the session-level one. Columns: `session, probe, animal, ks4_ok, tdc2_ok, consensus_ok, clean_ks4_units, clean_tdc2_units, n_warnings, warning_files`. Unit counts pulled from `advanced_curation_*.json`. First run: 97 probes, 90 all-OK, 7 incomplete (1× known 0-unit case on 1033993_day1_imec1; 6× batch3-era probes missing `consensus_clean.json`: 986168 d1/d3 imec1, 986171 d3 imec0, 986235 d2 imec0/imec1, 986235 d3 imec1).
- [Anil] Copied batch 6 data onto dardel.
rsync -av --partial --info=progress2 \
    --bwlimit=30M \
    -e "ssh -c aes128-gcm@openssh.com -o Compression=no" \
    /mnt/smb/dmclab/Joana/PFC-Str_behavior_project/Recordings/Raw_data/{1021218,1053833,1060138,1031913,1060360,1033996} \
    dardelcopy:/cfs/klemming/projects/supr/dmclab/Joana/Raw_data/

- [Claude] Added 1033996 (904 GB raw, 4 days complete) to `Joana/ephys_batch6/` staging. Batch6 is now 6 animals: 1021218, 1053833, 1060138, 1031913, 1060360, 1033996 (~6.5 TB raw total). Anil chose 1033996 over 1061234 because it's the newest "complete" animal (4 days).
- [Claude] Deleted `pfcv2/` (292 GB; 999770_day1 SC2+Lupin+MS5) and `pfcv3/` (446 GB; 986169 d1+d2 TDC2+SC2+Lupin) from Dardel — user-confirmed acceptance of SC2/Lupin/MS5 loss (KS4+TDC2 from batch5 on KI are canonical going forward). Storage 54% → 52% used, free 14.16 TiB.
- [Claude] Verified all 22 sessions (16 batch4 + 6 batch5) backed up to KI byte-for-byte; deleted `pfcv3-batch4/` (4.0 TB) and `pfcv3-batch5/` (1.5 TB) from Dardel. Storage 73% → 54% used, 8 TiB → 13.4 TiB free. Headroom for ~10 more animals in batch6 + future cohort if streaming (upload→process→rsync→delete).
- [Claude] Verified batch4 results fully on KI (16 sessions, all KS4=2/2 + TDC2=2/2, no symlinks).
- [Claude] Verified batch6 raw not yet on Dardel — upload from dmc-spike not started or not yet landed.
- [Claude] Created this OPERATIONS_LOG.md.



## 2026-06-16

- [Claude] Patched `06-compare.py`: guard against empty input sorting (skip `si.compare_two_sorters` when either side has 0 units, write empty COMPARE_CLEAN output). Fixes `unit_ids dtype` ValueError seen on 1033993_day1_imec1 in batch4.
- [Claude] Patched `main.nf` ADVANCED_CURATE + ADV_CURATE_LPN: declared `advanced_curation_*.WARNING` as optional published output so the sentinel file lands in `results/<sid>/<probe>/`.
- [Claude] Patched `07-advanced-curate.py`: try/except around UnitRefine noise + SUA/MUA classifiers and `compute_merge_unit_groups`; fall back to "unknown" labels with status fields in JSON and a `*.WARNING` sentinel file. Fixes SimpleImputer crash on 0-unit / all-NaN-features sortings.
- [Claude] Patched `pfcv3/nextflow.config` SORT_TDC2 + ANALYZE_KS4: `errorStrategy = 'retry'`, `maxRetries = 1`, attempt-2 time = 1440m. Attempt-1 unchanged so cache hashes for already-COMPLETED tasks stay valid.
- [Claude] Submitted batch4 `-resume` (job 21555068) — recovered 1020227_day1_imec1 (retry-time bump worked) and the 1033993_day1_imec1 advanced_curate (try/except worked). One residual `cons=1/2` on 1033993_day1_imec1 acceptable (clean KS4 has 0 units, consensus is undefined).
- [Claude] Staged `Joana/ephys_batch6/` with 20 symlinks for 1021218, 1053833, 1060138, 1031913, 1060360 (4 days each, broken until raw arrives).
- [Claude] Created `pfcv3/slurm_submit_batch6.sh` (clone of batch5 with paths bumped).

## 2026-06-15

- [Anil] Started rsync of pfcv3-batch5 results to KI via dmc-spike. Completed; all 6 sessions on KI, no symlinks.
- [Claude] Submitted batch4 (job 21436417) — processed 16 sessions; 14/16 fully done, 2 partial (1020227_day1_imec1: SORT_TDC2+ANALYZE_KS4 timed out; 1033993_day1_imec1: ADVANCED_CURATE KS4 crashed on SimpleImputer).
- [Anil] Started rsync of batch4 raw (4.1 TB) from dmc-spike to Dardel.

## 2026-06-10

- [Claude] Patched `arm-apptainer/kilosort4-arm.def`: pinned base image to `pytorch:25.12-py3` (CUDA 13.0) to match Dardel GH200 host driver. Was 26.02-py3 (CUDA 13.1) → cuFFT_INTERNAL_ERROR via broken forward-compat shim under apptainer's read-only FS.
- [Claude] Patched `build-ks4.sh`: added Test 9 (cuFFT smoke test at three sizes incl. kilosort-style 16384×32) so future CUDA mismatches are caught at build time.
- [Claude] Rebuilt KS4 SIF (job 21419618). All 9 tests passed. Swapped in. Backed up the broken CUDA-13.1 SIF as `.cuda131-bak` (later deleted on 2026-06-13 after batch5 KS4 ran clean).
- [Claude] Updated `arm-apptainer/KS4-GH200-EXPLAINER.md` documenting the three June 2026 Dardel breakages and fixes.
- [Claude] Cleanup: deleted `pfcv2/work/` (freed 5.2 TB), KS4+TDC2 dirs in `pfcv2/results/999770_day1_g0/` (~50 GB), `Joana/Raw_data/986169` + `/999770` (~1.6 TB, raw already on KI), broken SIF backups (~19 GB). Storage 95% → 73% used.

## 2026-06-09

- [Claude] Patched `pipeline/bin_gh200/apptainer` wrapper: dynamic discovery of libfabric + papi paths (`ls .../*/lib64 | sort -V | tail -1`) instead of hardcoded `1.22.0`. Dardel updated GH200 nodes' libfabric from 1.22.0 → 2.3.1 which broke the hardcoded path.
- [Claude] Patched `build-ks4.sh`: SIF compression `lz4 → xz` because newer squashfuse_ll on GH200 no longer supports lz4.

## 2026-06-08

- [PDC] Dardel rolled OS image update on GH200 partition. Broke three things in sequence: libfabric path, squashfs lz4 support, and CUDA-driver / shim compatibility. See `arm-apptainer/KS4-GH200-EXPLAINER.md` for full diagnosis.
- [Claude] Deleted `pfcv3-test/`, `pfcv3-batch2/`, `pfcv3-batch3/` from Dardel (verified safely on KI first). Freed ~8.5 TB.
- [Claude] Submitted batch4 (16 sessions: 1020227, 1021219, 1031912, 1033993) and batch5 (6 sessions: 986169, 999770) — batch5 with `afterany` dependency on batch4. Both job IDs lost to time, see git log around 2026-06-08 commits.

## 2026-06-03

- [Claude] Built initial `pfcv3_status.sh` CSV-output status tool. Outputs `PFC_STATUS.csv` in `Analysis/`.

## 2026-05-09 (approximate)

- Last successful KS4 run on Dardel GH200 before the June 8 system update broke things. KS4 ran fine for ~hours per batch.

## ~2026-04-09 to 2026-05-09

- batch1 / batch2 / batch3 era. Multiple runs as the pipeline was stabilized
  (SORT_KS4_BATCH multi-GPU batching, error strategy, retry patterns, advanced
  curation chain). See git log on `projects/pfcv3/main.nf` and
  `nextflow.config` for details.

## 2026-03 (earlier)

- KS4 SIF first built (`pytorch:26.02-py3` base, OpenBLAS 288-thread fix for
  Grace CPU). See `KS4-GH200-EXPLAINER.md` for the full story of why the
  GH200/ARM stack required so much patching to get KiloSort4 running at all.
