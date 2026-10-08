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
