#!/usr/bin/env python3
"""Run the frozen report against a symlinked, separate read-only input view.

Existing per-shank outputs and the prior failed partial report remain untouched.
Only the new report_20261009 directory receives generated files.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import sys


SESSIONS = (
    "cohort07/20260501/vr2220260501_g0",
    "cohort08/20260719/vr2520260719_g0",
    "cohort09/20260921/vr2820260921_g0",
    "cohort08/20260721/vr2320260721_g0",
)


def link(source, target):
    assert source.exists() and not source.is_symlink(), source
    assert not target.exists() and not target.is_symlink(), target
    target.parent.mkdir(parents=True, exist_ok=True)
    target.symlink_to(source.resolve(), target_is_directory=source.is_dir())


def stage(test, destination):
    assert not destination.exists() and not destination.is_symlink(), destination
    all_inputs = []
    for rel in SESSIONS:
        for group in range(4):
            root = test / rel / f"group{group}"
            name = f"block0_imec0.ap_recording1_group{group}"
            sources = [(root / "curation_complete", destination / rel / f"group{group}/curation_complete"),
                       (root / "heldout_waveform_stability.csv", destination / rel / f"group{group}/heldout_waveform_stability.csv")]
            for arm in ("uncorrected", "native_motion_interpolated"):
                data = root / arm
                report_data = destination / rel / f"group{group}" / arm
                sources.extend([
                    (data / "postprocessing/capsule/results" / f"postprocessed_{name}.zarr",
                     report_data / "postprocessing/capsule/results" / f"postprocessed_{name}.zarr"),
                    (data / "curation/capsule/results" / f"unit_labels_{name}.csv",
                     report_data / "curation/capsule/results" / f"unit_labels_{name}.csv"),
                ])
            all_inputs.extend(sources)
    assert len(all_inputs) == 16 * 6
    assert all(source.exists() and not source.is_symlink() for source, _ in all_inputs), "Incomplete replay; no report staged"
    destination.mkdir(parents=True)
    link(test / "model_provenance.json", destination / "model_provenance.json")
    for source, target in all_inputs:
        link(source, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    args = parser.parse_args()
    u = args.user_root.resolve()
    test = u / "baseline_pilots/ks4_native_motion_trace_test_20261008"
    report = test / "report_20261009"
    source = test / "source/ks4_motion_trace_report.py"
    assert source.is_file()
    # Fail before creating a destination if the pinned cache has changed.
    from ks4_motion_trace_models import check_models
    model_check = check_models(u)
    stage(test, report)
    sys.path.insert(0, str(test / "source"))
    spec = importlib.util.spec_from_file_location("frozen_ks4_report", source)
    frozen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(frozen)
    assert frozen.SESSIONS == SESSIONS
    frozen.TEST = str(report.relative_to(u))
    (report / "offline_model_check.json").write_text(json.dumps(model_check, indent=2) + "\n")
    frozen.results(args)
    assert (report / "REPORT.md").is_file() and (report / "comparison.csv").is_file()
    (report / "report_complete").write_text("passed\n")
    print(f"Separate full report: {report}/REPORT.md", flush=True)


if __name__ == "__main__":
    main()
