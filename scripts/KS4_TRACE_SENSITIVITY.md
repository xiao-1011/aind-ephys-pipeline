# KS4 analyzer trace sensitivity test

The four completed KS4-native pilots are retained unchanged. This test does not
sort again or alter raw inputs, batch manifests, or verified session archives.

For each of the 16 shanks, replay the pinned postprocessing capsule twice:

- Control: original filtered/referenced, non-whitened binary, cast to float32.
- Motion: that binary interpolated using the **saved KS4 motion estimate**,
  cast to float32. SI kriging uses sigma 20 µm, p=2 and force-extrapolate to
  retain all channels, matching the previous DREDge interpolation settings.

Using saved motion avoids independently estimating a new field. It does **not**
exactly reproduce KS4's internal interpolation/whitening order. Motion times must
overlap the recording's absolute time range; do not reset times before correction.

Both arms retain the historical analyzer's unit IDs and sparse channel masks,
disable duplicate removal, and use seed 0 for waveform/noise sampling. A small,
recorded capsule patch supplies fixed sparsity. The analyzers are separate,
and the capsule code is **copied**, not symlinked (relative output paths otherwise
write into the pilot source). Corrected binaries are materialized because SI
0.105.0's InterpolateMotionRecording is not JSON serializable. Nothing is cleaned.

The checksummed SI #4830 image runs curation in both arms. UnitRefine model
revisions are checked before and after replay against the prior verification's
frozen snapshots; a changed model revision blocks completion.

The report includes paired QC/SUA counts, per-unit labels and metrics, and
four-quarter average waveform consistency on identical held-out spikes. The
waveform plots use the same original channel in both arms. Increased QC/SUA counts
alone are not evidence of improved sorting, nor is interpolated waveform
consistency proof of accuracy. Review edge channels, amplitude/SNR changes, and
units that switch labels before promoting a trace policy. Fixed historical masks
isolate the trace effect but are not a production corrected-sparsity benchmark.

Submit a frozen copy of `ks4_motion_trace_replay.sh` as `--array=0-15%4`, setting
`KS4_TRACE_SCRIPT` to its frozen Python companion. Sources under the pilot root,
raw data, and archives are mounted read-only. Reports go under
`$U/baseline_pilots/ks4_native_motion_trace_test_20261008/`.

After the array succeeds, run the Python script's `report --user-root "$U"`
mode in pipeline-base 1.4.0. It verifies identical spike vectors and unit IDs
and writes `REPORT.md`, `comparison.csv`, `waveform_stability_summary.json`,
and per-shank metric/label comparisons. The full KS4 batch is **not** launched.

## 2026-10-09: two-shank contextual trace recovery

The original array 3541170 completed 14/16 shanks. Indices 5/6 (cohort08
vr2520260719_g0, groups 1/2) failed a strict equality check comparing their
saved 1-second-chunk float32 binary against direct **100-frame** interpolation.
The report 3541251 failed closed and wrote no `report_complete` marker.

Read-only compute-node diagnostic 3562411 checked successful group0 and both
failures. All sampled traces are finite, use the same channels and absolute time,
and direct requests repeat exactly. Only the 100-frame requests differed: at
most 9.54e-7 / 1.91e-6 for groups 1/2, mainly on edge channels. Requesting
the same frames with surrounding context (including windows across 1-second
chunk boundaries) matches the retained binary **bit for bit**. This is a
request-window numerical effect, not evidence of shifted frames or corrupt
binary data. Do not silently substitute a tolerance for exact validation.

Recovery array 3562854 uses *only* existing incomplete group1/2 directories,
their retained 20 GB corrected binaries and original fixed sorting/sparsity.
It checks 25 deterministic contextual windows for exact, finite agreement
before staging the missing control/postprocessing/curation arms. It checks the
corrected binary SHA-256 again after postprocessing. Completed shanks, pilot
outputs, raw, and archives are untouched. Frozen sources, checksums, diagnostics
and logs live in `baseline_pilots/ks4_native_motion_trace_test_20261008/
diagnostics_20261009/`. Three synthetic tests cover exact contextual recovery,
shift rejection, and nonfinite rejection. Regenerate the aggregate report only
after both recovery tasks succeed and all 16 `curation_complete` markers exist.

The new report job **3563214** has an `afterok:3562854` dependency and writes
only to `report_20261009/` via a symlinked read-only input view. It requires
all 16 completion markers, verifies the frozen reporter checksums, and leaves
both the 14 completed shanks and the previous failed partial report untouched.
The aggregate report is valid only if `report_20261009/report_complete` exists.

Preliminary read-only inspection of the 14 completed shanks found mostly lower
QC-pass SUA counts and lower four-quarter waveform cosine under interpolation.
These counts and held-out measures concern this **postprocessing** trace policy
with historical masks; they do not establish that KS4's built-in sorting
correction is inaccurate. No final trace recommendation or full batch yet.

### 2026-10-09: shared-IP Hugging Face API limit

Recovery task 3562854_5 completed with its retained corrected binary hash
unchanged (15/16 completion markers). Task 3562854_6 and its clean retry
3563933_6 both failed **before staging** at the live Hugging Face HEAD check:
HTTP 429 on the cluster's shared IP, even after a delayed retry. Neither
modified group2. The dependent reports 3563214/3564469 were cancelled or
dependency-failed without creating `report_20261009/`.

For group2 only, a newly checksummed recovery source uses a local, fail-closed
model verifier instead of querying the rate-limited live API. It validates the
two exact pinned repo/revision pairs, cached `refs/main`, file sets, and SHA-256
of **all files** in both the recorded SI #4830 verification snapshots and the
actual replay HF cache. This attests to the model bytes the curation uses;
it **does not claim to prove the upstream HEAD is unchanged**. The original
frozen replay/report sources and prior failed checks are retained. Fresh
recovery and report jobs write job IDs/logs and new source hashes under
`diagnostics_20261009/` (offline prefix). The report still requires all 16
completion markers and writes only to its isolated view.

### Final paired downstream trace result, 2026-10-09

Offline-verified group2 recovery **3565490_6** completed, exit 0: 25/25
contextual windows matched the retained corrected binary exactly; the saved
binary hash was unchanged; both curation arms completed. Isolated aggregate
report **3565491** completed, exit 0, with all **16/16** shanks and
`report_20261009/report_complete: passed`. The complete report and all 16
per-shank matched-unit labels and QC metrics live under `report_20261009/`.
The two 429 retries and the original failed report remain recorded.

For the four follow-up sessions (2,185 **identical** sorted unit IDs in each
trace arm), QC-pass is **753 uncorrected vs 736 SI-interpolated**, and QC-pass
SUA is **288 vs 122**. Matching unit labels directly: 195 SUA labels were
lost (166 to MUA, 29 to noise), three SUA labels gained, and only 23 units
changed default-QC status. Of the originally QC-pass SUA, 167 ceased to be
QC-pass SUA and one gained that combined status. Held-out four-quarter
template cosine decreased in median by 0.038–0.090 in **every** session;
the fraction improved was 0.001–0.026. Median peak-channel quarter range
increased by 15–45 um. Sampled waveform plots illustrate variability; they
are not ground truth or a representative independent sample.

The five-session restore-verified archive comparison (including the initial
KS4 pilot and separately recovered DREDGE session) yields KS4 vs DREDGE:

| Session | KS4 units / QC / QC-SUA | DREDGE units / QC / QC-SUA |
|---|---:|---:|
| vr1520260318_g0 | 807 / 388 / 181 | 803 / 344 / 216 |
| vr2220260501_g0 | 703 / 297 / 153 | 702 / 282 / 215 |
| vr2520260719_g0 | 570 / 141 / 39 | 621 / 121 / 96 |
| vr2820260921_g0 | 591 / 250 / 68 | 637 / 204 / 128 |
| vr2320260721_g0 | 321 / 67 / 29 | 345 / 63 / 34 |
| **Total** | **2992 / 1143 / 470** | **3108 / 1014 / 689** |

Across 20 paired shanks, KS4 has more QC-pass units on 15 and more QC-pass
SUA on only two. These are **different sorts and different analyzer traces**;
the archive counts cannot isolate sorting-time motion correction. In contrast,
the trace replay holds sorting fixed but uses SI interpolation, not KS4's
internal algorithm or updated channel masks. Keep the current uncorrected
postprocessing policy for these pilots; do not adopt this SI-interpolated
analyzer recipe on count changes alone. Visually review motion jumps, border
channels, and representative SUA transitions before any production decision.
No full baseline batch, source deletion, or manifest change was authorized.

## Progress checkpoint: 2026-10-08 21:10 CEST

- Active array: **3541170** (16 shanks, concurrency 4).
- At this check: **3 completed, 4 running, 2 failed, 7 queued**.
  Completed indices 0/1/2 are groups 0/1/2 of `vr2220260501_g0`.
- Failed indices **5/6** are groups 1/2 of `vr2520260719_g0`.
  Both stopped at the strict `np.array_equal` comparison of reloaded corrected
  binary samples against directly interpolated samples, before postprocessing.
  The cause is not yet diagnosed; all new binaries and logs are retained.
- Dependent report: **3541251**; detached report-return job: **3541288**.
  The report must fail closed while any shank lacks `curation_complete`.
  No completed-report marker or scientific trace recommendation exists yet.
- First array **3541131** failed on malformed read-only bind arguments before
  computation. Its pending tasks and dependent report **3541141** were canceled.
  Corrected `source:destination:ro` mounts were verified in `/proc/self/mounts`.
- Queued report **3541171** was superseded by 3541251. A separate report-only
  Python snapshot adds SUA gain/loss and additional waveform summaries without
  changing the running replay source. Snapshot hashes are retained on the cluster.

Next: inspect the saved/direct trace differences for failed groups (magnitude,
finite values, channel/time alignment, interpolation bin and chunk behavior)
before changing the equality criterion. Resume only failed tests in fresh or
explicitly inspected recovery directories; do not overwrite successful results.
Then verify all 16 paired outputs and inspect waveform/metric changes before
recommending analyzer traces or launching the full KS4 baseline.
