#!/usr/bin/env python3
"""Aggregate 20 fixed-sort DREDGE trace replays, failing closed if incomplete."""

import csv
import json
from pathlib import Path

import numpy as np
import pandas as pd
import spikeinterface as si

import dredge_trace_models
from dredge_trace_probe import SESSIONS, TEST
from dredge_trace_replay import ARMS


def analyze(user_root):
    user_root = Path(user_root)
    test = user_root / TEST
    out = test / "report_20261009"
    assert not out.exists() and not out.is_symlink(), out
    # Do not create a partial report directory for a failed or running shank.
    entries = []
    for rel in SESSIONS:
        assert (test / "staged" / rel / "stage_complete").read_text().strip() == "passed"
        for group in range(4):
            root = test / "replays" / rel / f"group{group}"
            assert (root / "curation_complete").read_text().strip() == "passed", root
            for arm in ARMS:
                assert (root / arm / "postprocessing_complete").read_text().strip() == "passed"
            entries.append((rel, group, root))
    assert len(entries) == 20
    dredge_trace_models.check_models(user_root)
    out.mkdir(parents=True)
    totals, stability = [], []
    for rel, group, root in entries:
        name = f"block0_imec0.ap_recording1_group{group}"
        source_analyzer = si.load_sorting_analyzer(test / "staged" / rel / "postprocessed" / f"{name}.zarr", read_only=True)
        analyzers = {arm: si.load_sorting_analyzer(root / arm / "postprocessing/capsule/results" /
                                                   f"postprocessed_{name}.zarr", read_only=True) for arm in ARMS}
        fixed = si.load(root / "fixed_sorting")
        masks = np.load(root / "fixed_sparsity.npy")
        for analyzer in (source_analyzer, *analyzers.values()):
            assert np.array_equal(analyzer.unit_ids, fixed.unit_ids), root
            assert np.array_equal(analyzer.sorting.to_spike_vector(), fixed.to_spike_vector()), root
            assert np.array_equal(analyzer.sparsity.mask, masks), root
        labels, metrics = {}, []
        for arm, analyzer in analyzers.items():
            path = root / arm / "curation/capsule/results" / f"unit_labels_{name}.csv"
            df = pd.read_csv(path)
            assert len(df) == len(fixed.unit_ids)
            assert df.default_qc.dtype == bool
            df = df.assign(unit_id=fixed.unit_ids).set_index("unit_id")
            assert df.index.is_unique
            labels[arm] = df
            q = analyzer.get_extension("quality_metrics")
            assert q is not None, (root, arm)
            m = q.get_data().copy()
            assert set(m.index) == set(fixed.unit_ids)
            m.index.name = "unit_id"
            metrics.append(m.reset_index().assign(trace=arm))
        before, after = (labels[arm] for arm in ARMS)
        q1, q2 = before.default_qc, after.default_qc
        s1, s2 = before.unitrefine_label == "sua", after.unitrefine_label == "sua"
        combined_before, combined_after = q1 & s1, q2 & s2
        per_shank = out / rel / f"group{group}"
        per_shank.mkdir(parents=True)
        for arm in ARMS:
            labels[arm].assign(trace=arm).to_csv(per_shank / f"{arm}_unit_labels.csv")
        pd.concat(metrics, ignore_index=True).to_csv(per_shank / "quality_metrics_comparison.csv", index=False)
        transitions = pd.DataFrame({"unit_id": fixed.unit_ids,
                                    "original_qc": q1.to_numpy(), "corrected_qc": q2.to_numpy(),
                                    "original_unitrefine": before.unitrefine_label.to_numpy(),
                                    "corrected_unitrefine": after.unitrefine_label.to_numpy(),
                                    "original_qc_sua": combined_before.to_numpy(),
                                    "corrected_qc_sua": combined_after.to_numpy()})
        transitions.to_csv(per_shank / "unit_transitions.csv", index=False)
        change = {"qc_gained": int((~q1 & q2).sum()), "qc_lost": int((q1 & ~q2).sum()),
                  "sua_gained": int((~s1 & s2).sum()), "sua_lost": int((s1 & ~s2).sum()),
                  "qc_sua_gained": int((~combined_before & combined_after).sum()),
                  "qc_sua_lost": int((combined_before & ~combined_after).sum()),
                  "changed_unitrefine": int((before.unitrefine_label != after.unitrefine_label).sum())}
        for arm, df, qc, sua in ((ARMS[0], before, q1, s1), (ARMS[1], after, q2, s2)):
            totals.append({"session": rel, "group": group, "trace": arm, "units": len(df),
                           "qc_pass": int(qc.sum()), "sua": int(sua.sum()), "sua_qc_pass": int((qc & sua).sum()), **change})
        waves = pd.read_csv(root / "heldout_waveform_stability.csv")
        waves.to_csv(per_shank / "heldout_waveform_stability.csv", index=False)
        stability.append(waves.assign(session=rel, group=group))
    pd.DataFrame(totals).to_csv(out / "comparison.csv", index=False)
    stability_df = pd.concat(stability, ignore_index=True)
    stability_df.to_csv(out / "heldout_waveform_stability.csv", index=False)
    summaries = []
    for rel in SESSIONS:
        waves = stability_df[stability_df.session == rel]
        a = waves[waves.trace == ARMS[0]].set_index(["group", "unit_id"])
        b = waves[waves.trace == ARMS[1]].set_index(["group", "unit_id"])
        assert a.index.is_unique and a.index.equals(b.index), rel
        delta = b.temporal_template_cosine - a.temporal_template_cosine
        amplitude = b.quarter_peak_amplitude_cv - a.quarter_peak_amplitude_cv
        channels = b.quarter_peak_channel_range_um - a.quarter_peak_channel_range_um
        summaries.append({"session": rel, "eligible_units": len(delta),
                          "median_temporal_cosine_change": float(delta.median()) if len(delta) else None,
                          "fraction_temporal_cosine_improved": float((delta > 0).mean()) if len(delta) else None,
                          "median_quarter_amplitude_cv_change": float(amplitude.median()) if len(delta) else None,
                          "median_peak_channel_range_change_um": float(channels.median()) if len(delta) else None})
    (out / "waveform_stability_summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    report = ["# DREDGE-100 fixed-sort analyzer trace replay", "",
              "Five paired sessions (20 shanks), fixed DREDGE sorting, unit IDs and historical DREDGE sparsity masks.",
              "The original arm uses KS4-pilot filtered/referenced uncorrected traces; the corrected arm uses",
              "the DREDGE archive's saved motion-corrected binary. Both are non-whitened float32 analyzer inputs.",
              "Duplicate removal is disabled and random waveform/noise sampling is seeded identically.",
              "This changes only the downstream analyzer trace; it is not a new sort or ground-truth evaluation.", "",
              "| Session | Arm | Units | QC | SUA | QC + SUA |", "|---|---|---:|---:|---:|---:|"]
    for rel in SESSIONS:
        for arm in ARMS:
            match = [r for r in totals if r["session"] == rel and r["trace"] == arm]
            report.append("| " + rel.split("/")[-1] + " | " + arm + " | " + " | ".join(str(sum(x[k] for x in match)) for k in ("units", "qc_pass", "sua", "sua_qc_pass")) + " |")
    report += ["", "## Matched-unit transitions (original → DREDGE-corrected)", "",
               "| Session | QC gained/lost | SUA gained/lost | QC-SUA gained/lost |",
               "|---|---:|---:|---:|"]
    for rel in SESSIONS:
        changes = [r for r in totals if r["session"] == rel and r["trace"] == ARMS[0]]
        report.append("| " + rel.split("/")[-1] + " | " + " | ".join(
            f"{sum(x[a] for x in changes)}/{sum(x[b] for x in changes)}" for a, b in
            (("qc_gained", "qc_lost"), ("sua_gained", "sua_lost"), ("qc_sua_gained", "qc_sua_lost"))) + " |")
    report += ["", "## Held-out four-quarter waveform consistency", "",
               "Positive cosine changes mean more consistent sampled templates, not proven sorting accuracy.",
               "```json", json.dumps(summaries, indent=2), "```", "",
               "Inspect per-unit transitions, QC metrics, quarter-waveform plots, motion jumps and edge channels",
               "before changing any analyzer policy. Original DREDGE archives, manifest and pilot shanks remain unchanged."]
    (out / "REPORT.md").write_text("\n".join(report) + "\n")
    dredge_trace_models.check_models(user_root)
    (out / "report_complete").write_text("passed\n")
    print(json.dumps({"shanks": len(entries), "report": str(out), "summaries": summaries}, indent=2), flush=True)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    args = parser.parse_args()
    analyze(args.user_root)
