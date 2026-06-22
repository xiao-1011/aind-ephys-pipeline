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
