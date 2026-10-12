# Motion/analyzer policy decision — 2026-10-12

## Recommendation

For single-unit analysis, retain **DREDGE-100 sorting with DREDGE-corrected
analyzer traces** as the default. Apply the correction once. Do not replace
it with original analyzer traces, or promote the tested saved-KS4-motion SI
interpolation recipe. KS4-native sorting with original analyzer traces remains
a valid comparator, but there is insufficient evidence to replace the existing
DREDGE cohort with a full KS4 batch.

**Policy selection is supported; the current metric configuration needs repair
before another production batch.** A confirmed SNR parameter/API mismatch
produces all-NaN SNR columns. The SNR-valid sensitivity check below preserves the
policy ranking. Existing DREDGE sorts need no rerun to repair this metric and
the dependent labels. All 35 DREDGE sessions already have verified archives.

## Evidence: five sessions, 20 fixed DREDGE sorts

The replay and report completed successfully. Report job `3584590` exited 0,
and `report_20261009/report_complete` is `passed`. Each arm retains the same
3,108 unit IDs, spike vectors, and historical DREDGE channel masks. Both
recordings are non-whitened float32 views of existing binaries.

| Measure | Original trace | DREDGE-corrected trace |
|---|---:|---:|
| Fixed sorted units | 3,108 | 3,108 |
| Default QC-pass | 1,005 | 1,012 |
| QC-pass UnitRefine SUA, original replay | 501 | 685 |
| QC-pass UnitRefine SUA, SNR-valid sensitivity | 492 | **682** |

The last row is an isolated in-memory classifier sensitivity check, not a
replacement production report. It gives +190 QC-SUA (+38.6%) with correction.
In both the original and SNR-valid comparisons, correction increases QC-SUA
on 18 shanks and ties on two; none decrease. Every session gains.

| Session | Original QC-SUA, valid SNR | Corrected QC-SUA, valid SNR |
|---|---:|---:|
| vr1520260318_g0 | 180 | 212 |
| vr2220260501_g0 | 143 | 210 |
| vr2520260719_g0 | 72 | 98 |
| vr2820260921_g0 | 70 | 131 |
| vr2320260721_g0 | 27 | 31 |

The original replay has 185 QC-SUA gains and one loss. Of its 290 total SUA
gains, 271 are MUA-to-SUA and 19 noise-to-SUA. There are six SUA losses.
Default QC gains/losses are only 10/3: changing the analyzer cannot repair
refractory violations, firing rates or spike times in a fixed sorting.
These spike-train metrics are identical across arms, as expected.

## Waveform and metric support

- Four-quarter waveform consistency improves in the median on **all 20
  shanks**, and on 2,764/2,833 eligible units (97.6%). Median cosine change
  is +0.0281; median peak-channel quarter range decreases by 30 um.
- All 183 evaluable units gaining QC-SUA improve in waveform consistency.
- With paired finite QC metrics, median drift peak-to-peak decreases by
  37.54 um (1,695 pairs), amplitude-CV median by 0.0350 (2,103 pairs),
  and isolation distance increases by 8.69 (3,090 pairs). These are
  supporting trace-derived measures, not independent sorting ground truth.
- Among units whose original template peak is within 100 um of a retained
  shank's top/bottom, 410/434 evaluable units improve (94.5%); original
  replay QC-SUA increases from 53 to 78. Interior improvements are also
  strong (2,354/2,399), so the benefit is not confined to borders.

### Independent challenge-waveform audit

The original reporter's “held-out” samples were separately seeded but did
not explicitly exclude postprocessing's random spikes, and each quarter was
compared to a mean including itself. Do not call that a strict hold-out test.

Read-only audit `3601723` (exit 0, `audit_complete: passed`) instead excludes
every postprocessing waveform spike, samples up to 24 fresh spikes per time
quarter, and compares each quarter with the other three. Both arms use the
same spikes, channels and plot y-axis. It evaluates 55 selected challenge
units, not a random population estimate:

- 18/18 median-gain examples improve; median leave-one-quarter-out cosine
  change +0.0957.
- 19/20 closest-edge QC-SUA examples improve; median change +0.0685.
- 11/16 evaluable worst-previous-cosine cases improve; five remain worse.
- The sole original-replay QC-SUA loss improves (+0.0391). Its original
  UnitRefine probabilities straddle the decision boundary: 0.518 SUA versus
  0.528 MUA. QC remains passing and isolation improves. It is not evidence
  for a population-wide waveform penalty.

Plots inspected include gain/edge/loss cases in vr15 group0, vr22 group0,
vr25 group2, vr28 group1, and vr23 group1. The latter's edge unit 12 is a
real exception (cosine 0.903 to 0.889); the recommendation is a default,
not a claim that every unit benefits.

The audit also verifies equal realized random-spike indices and masks in
all 20 shanks, matching dtype/gains/offsets/geometry between trace arms,
and finite stored templates/noise levels.

### Motion review

Saved motion arrays were read from the archives and checked against their
member hashes. All 20 fields are finite and rigid with increasing 1-second
time bins. Plots show sustained motion as well as abrupt transitions;
maximum adjacent changes range from 9.95 to 73.98 um. Quarter averages do
not validate each jump interval. The low-yield vr23 groups 0/1 show especially
irregular/flat or linearly filled stretches and no QC-SUA advantage; retain
them as explicit motion-quality review cases. Do not infer a need for a
global original-trace policy from those local exceptions.

## Confirmed metric compatibility issue

The pinned SI image exposes
`compute_snrs(sorting_analyzer, unit_ids=None, method="extremum")`.
Frozen parameters still provide `peak_sign` and `peak_mode`; passing them
raises `TypeError`. SI's metric dispatcher catches such exceptions and
fills NaN, allowing the capsule/job to finish successfully. The reported
SNR and SD-ratio columns contain no finite entries in either arm.

SNR sensitivity job `3601749` completed, exit 0, with
`snr_sensitivity_complete: passed`. It:

1. Loads the exact previously hashed local UnitRefine models in the pinned
   SI #4830 image, with no live model substitution.
2. Reproduces **all 40 original label vectors and probabilities** before
   changing metrics, also checking CSV/unit-ID alignment.
3. Calculates valid SNR from each saved analyzer's templates/noise through
   the supported function, changes only that metric in memory, and predicts
   again. All 40 SNR vectors are finite; the 492/682 result above follows.

For the next production configuration, use `snr: {"method": "extremum"}`;
the analyzer settings already specify both-sign extrema. Investigate/validate
SD-ratio compatibility as well: its signature no longer explicitly accepts
the legacy `peak_sign` parameter, which is currently passed via job kwargs.
SD-ratio is not among either pinned model's required features, so its missing
values do not invalidate this SNR-only classification sensitivity check.
Do not silently treat successful jobs as proof all requested metrics worked.

Default QC thresholds (`rp_contamination`, `presence_ratio`, `amplitude_cutoff`)
do not use SNR or SD-ratio, so archived QC-pass status is unaffected. Bombcell's
MUA rule does require `snr > 5`, so archived Bombcell labels are also affected.
Across all 40 replay analyzers, `snr` and `sd_ratio` are the only quality-metric
columns with no finite value.

Validate repaired metrics/curation on preserved inputs before cohort-wide
downstream reprocessing, and save repaired outputs under a new namespace.
The existing reports and archived labels remain historical evidence.

## Relation to KS4 and operational policy

The completed four-session **fixed-KS4-sort** test favored original analyzer
traces over the tested SI interpolation of saved KS4 motion: 288 versus 122
QC-SUA, with median waveform consistency worsening in every session.
That rejects this particular downstream recipe, not native KS4 sorting-time
motion correction.

The five-session archive comparison has more QC-pass units for KS4 than
DREDGE (1,143 versus 1,014), but fewer QC-SUA (470 versus 689). These are
different sorts and historical analyzer runs; they cannot establish sorter
accuracy or be directly pooled with the SNR-valid sensitivity counts.
For an objective focused only on total QC yield, the end-to-end ranking is
less decisive. For the intended single-unit analysis, DREDGE plus corrected
traces is the best-supported tested default.

Preserve the verified DREDGE-100 motion settings (rigid, max_disp_um 100,
kriging sigma 20 um / p=2, force_extrapolate). For new sorting, preprocessing
compute/apply are true and KS4 `skip_motion_correction` is true. Feed the
saved corrected recording to the analyzer; do not apply motion a second
time. In the frozen pipeline, `postprocessing.use_motion_corrected` remains
false because correction has already occurred upstream. Verify the actual
analyzer recording rather than interpreting this flag as “uncorrected”.

No full KS4 batch, sorting rerun, archive replacement or manifest change
was performed as part of this review. The local active parameters still
describe the KS4 pilot; this document records a recommendation, not a
silent production configuration change.

## Evidence locations

Under `/nobackup/proj/disk/dmclab/personal/xiao1011/`:

- DREDGE report: `baseline_pilots/dredge100_original_trace_20261009/report_20261009/`
- Read-only audit sources, hashes, jobs, plots and CSVs:
  `baseline_pilots/dredge100_original_trace_20261009/policy_review_20261009/`
  (`unit_edge_template_audit.csv`, `motion_audit.csv`,
  `independent_challenge_waveforms.csv`, `snr_sensitivity_summary.csv`,
  `snr_sensitivity_units.csv`, `input_checks.json`, `metric_compatibility.json`).
- Frozen DREDGE production parameters:
  `batch_runs/20261006_180017/snapshot/pipeline/active_params.json`.
- KS4 trace report:
  `baseline_pilots/ks4_native_motion_trace_test_20261008/report_20261009/`.
