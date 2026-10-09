#!/usr/bin/env python3
"""Replay postprocessing/curation on fixed DREDGE-100 sorted units only.

Two float32 (not whitened) lazy recording views: original filtered/referenced
traces from matched verified KS4 pilot and corrected DREDGE archive binary.
Everything generated lives in a new namespace; no archive/source is modified.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np
import spikeinterface as si
import spikeinterface.preprocessing as spre

import dredge_trace_models
from dredge_trace_probe import SESSIONS, TEST, source_paths
import ks4_motion_trace_replay as frozen


ARMS = ("original", "dredge_corrected")
PATCH_FROM = "sorting=sorting, recording=recording_bin, sparse=True, return_in_uV=return_in_uV, **sparsity_params"
PATCH_TO = "sorting=sorting, recording=recording_bin, sparsity=si.ChannelSparsity(np.load('../data/fixed_sparsity.npy'), unit_ids=sorting.unit_ids, channel_ids=recording_bin.channel_ids), return_in_uV=return_in_uV"


def validate_versions(pilot, staged):
    native = (pilot / "source/pipeline/capsule_versions.env").read_text()
    dredge = (staged / "archive_provenance/capsule_versions.env").read_text()
    assert native == dredge, "Pinned capsule versions differ"
    a = json.loads((pilot / "source/pipeline/active_params.json").read_text())
    b = json.loads((staged / "archive_provenance/active_params.json").read_text())
    assert not a["preprocessing"]["motion_correction"]["apply"]
    assert b["preprocessing"]["motion_correction"]["apply"]
    for key in ("compute", "apply"):
        b["preprocessing"]["motion_correction"][key] = a["preprocessing"]["motion_correction"][key]
    b["spikesorting"]["kilosort4"]["skip_motion_correction"] = a["spikesorting"]["kilosort4"]["skip_motion_correction"]
    assert a == b, "Non-motion pipeline settings differ"


def sample_checks(recordings):
    original, corrected = recordings
    assert original.get_num_segments() == corrected.get_num_segments() == 1
    assert np.array_equal(original.channel_ids, corrected.channel_ids)
    assert original.get_num_frames() == corrected.get_num_frames()
    assert original.sampling_frequency == corrected.sampling_frequency
    assert np.array_equal(original.get_times()[[0, -1]], corrected.get_times()[[0, -1]])
    n = original.get_num_frames()
    samples = []
    for fraction in (0.1, 0.5, 0.9):
        start = int(n * fraction)
        data = [rec.get_traces(start_frame=start, end_frame=start + 1000) for rec in recordings]
        assert data[0].shape == data[1].shape
        assert np.isfinite(data[0]).all() and np.isfinite(data[1]).all()
        samples.append({"frame": start, "max_absolute_trace_difference": float(np.max(np.abs(data[0].astype("float64") - data[1].astype("float64"))))})
    assert any(x["max_absolute_trace_difference"] > 0 for x in samples), "Motion correction had no measurable effect"
    return samples


def stage_capsule(root, arm, name, recording_json, recorded_folder, pp_code, params):
    pp = root / arm / "postprocessing/capsule"
    (pp / "data").mkdir(parents=True)
    (pp / "results").mkdir()
    (pp / "scratch").mkdir()
    shutil.copytree(pp_code, pp / "code")
    code = pp / "code/run_capsule.py"
    text = code.read_text()
    assert text.count(PATCH_FROM) == 1
    code.write_text(text.replace(PATCH_FROM, PATCH_TO))
    frozen.link(pp / "data" / f"binary_{name}.json", recording_json)
    # Only for the pinned capsule's name discovery. The actual analyzer input
    # is always loaded from binary_NAME.json, verified again after the run.
    frozen.link(pp / "data" / f"preprocessed_{name}", recorded_folder)
    frozen.link(pp / "data" / f"spikesorted_{name}", root / "fixed_sorting")
    frozen.link(pp / "data/fixed_sparsity.npy", root / "fixed_sparsity.npy")


def run_postprocessing(root, name, params):
    for arm in ARMS:
        capsule = root / arm / "postprocessing/capsule"
        subprocess.run([sys.executable, "-u", "run_capsule.py", "--params", json.dumps(params)],
                       cwd=capsule / "code", check=True)
        analyzer = capsule / "results" / f"postprocessed_{name}.zarr"
        assert analyzer.is_dir(), analyzer
        (root / arm / "postprocessing_complete").write_text("passed\n")


def heldout(root):
    """Same spike samples and original channel mask for both trace arms."""
    import pandas as pd
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    sorting = si.load(root / "fixed_sorting")
    mask = np.load(root / "fixed_sparsity.npy")
    recordings = {arm: si.load(root / f"{arm}_recording.json", base_folder=root) for arm in ARMS}
    rng = np.random.default_rng(1729)
    n = recordings[ARMS[0]].get_num_frames()
    before, after = 60, 90
    rows, plots = [], []
    for i, unit in enumerate(sorting.unit_ids):
        spikes = sorting.get_unit_spike_train(unit)
        channels = np.flatnonzero(mask[i])
        if not channels.size:
            continue
        frames = []
        for quarter in range(4):
            eligible = spikes[(spikes >= max(before, quarter * n // 4)) &
                              (spikes < min(n - after, (quarter + 1) * n // 4))]
            frames.append(rng.choice(eligible, min(16, len(eligible)), replace=False))
        if any(len(x) < 8 for x in frames):
            continue
        templates = {}
        for arm, recording in recordings.items():
            waves = np.stack([np.mean([recording.get_traces(start_frame=int(f) - before,
                                                               end_frame=int(f) + after,
                                                               channel_ids=recording.channel_ids[channels])
                                       for f in quarter], axis=0) for quarter in frames])
            templates[arm] = waves
            flat = waves.reshape(4, -1)
            average = flat.mean(axis=0)
            cosine = flat @ average / (np.linalg.norm(flat, axis=1) * np.linalg.norm(average) + 1e-12)
            amplitude = np.max(np.abs(waves), axis=(1, 2))
            peak_channels = channels[np.max(np.abs(waves), axis=1).argmax(axis=1)]
            y = recording.get_channel_locations()[peak_channels, 1]
            rows.append(dict(unit_id=unit, trace=arm, temporal_template_cosine=float(cosine.mean()),
                             quarter_peak_amplitude_cv=float(amplitude.std() / (amplitude.mean() + 1e-12)),
                             quarter_peak_channel_range_um=float(np.ptp(y)), sampled_spikes=sum(map(len, frames))))
        if len(plots) < 12:
            plots.append((unit, channels, templates))
    pd.DataFrame(rows, columns=("unit_id", "trace", "temporal_template_cosine", "quarter_peak_amplitude_cv",
                                "quarter_peak_channel_range_um", "sampled_spikes")).to_csv(root / "heldout_waveform_stability.csv", index=False)
    if plots:
        fig, axes = plt.subplots(len(plots), 2, figsize=(10, 2 * len(plots)), squeeze=False)
        for row, (unit, channels, templates) in enumerate(plots):
            ref = templates[ARMS[0]].mean(axis=0)
            channel = np.max(np.abs(ref), axis=0).argmax()
            for col, (arm, waves) in enumerate(templates.items()):
                for quarter, wave in enumerate(waves):
                    axes[row, col].plot(np.arange(-before, after) / 30, wave[:, channel], label=f"Q{quarter + 1}")
                axes[row, col].set_title(f"unit {unit}, {arm}, original channel {channels[channel]}")
        axes[0, 0].legend()
        fig.tight_layout()
        fig.savefig(root / "heldout_quarter_waveforms.png", dpi=120)
        plt.close(fig)


def prepare(user_root, index):
    u, rel, pilot, archive_report = source_paths(user_root, index // 4)
    group = index % 4
    name = f"block0_imec0.ap_recording1_group{group}"
    test = u / TEST
    staged = test / "staged" / rel
    assert (staged / "stage_complete").read_text().strip() == "passed"
    validate_versions(pilot, staged)
    dredge_trace_models.check_models(u)
    root = test / "replays" / rel / f"group{group}"
    assert not root.exists() and not root.is_symlink(), root
    source_json = pilot / "outputs" / rel / "preprocessed" / f"{name}.json"
    corrected_json = staged / "preprocessed" / f"{name}.json"
    original = si.load(source_json, base_folder=source_json.parent)
    corrected = si.load(corrected_json, base_folder=corrected_json.parent)
    samples = sample_checks((original, corrected))
    historic = si.load_sorting_analyzer(staged / "postprocessed" / f"{name}.zarr", read_only=True)
    assert np.array_equal(historic.recording.channel_ids, corrected.channel_ids)
    assert historic.recording.get_num_frames() == corrected.get_num_frames()
    for item in samples:
        f = item["frame"]
        assert np.array_equal(historic.recording.get_traces(start_frame=f, end_frame=f + 1000),
                              corrected.get_traces(start_frame=f, end_frame=f + 1000)), "Archived analyzer did not use corrected binary"
    pp_code, pp_args = frozen.capsule_source(pilot / "work" / rel, "postprocessing", group)
    cur_code, cur_args = frozen.capsule_source(pilot / "work" / rel, "curation", group)
    pp_params = json.loads(pp_args)
    assert pp_params["use_motion_corrected"] is False
    assert "unitrefine" in json.loads(cur_args)["noise_strategy"]
    assert np.array_equal(historic.sparsity.channel_ids, corrected.channel_ids)
    root.mkdir(parents=True)
    historic.sorting.save(folder=root / "fixed_sorting")
    np.save(root / "fixed_sparsity.npy", historic.sparsity.mask)
    fixed = si.load(root / "fixed_sorting")
    assert np.array_equal(fixed.unit_ids, historic.unit_ids)
    assert np.array_equal(fixed.to_spike_vector(), historic.sorting.to_spike_vector())
    pp_params["duplicate_threshold"] = None
    pp_params["extensions"]["random_spikes"]["seed"] = 0
    pp_params["extensions"]["noise_levels"]["random_slices_kwargs"]["seed"] = 0
    for arm, source in zip(ARMS, (original, corrected)):
        view = spre.astype(source, "float32")
        view_json = root / f"{arm}_recording.json"
        view.dump(view_json)
        reloaded = si.load(view_json, base_folder=root)
        assert reloaded.dtype == np.dtype("float32")
        assert np.array_equal(reloaded.get_times()[[0, -1]], source.get_times()[[0, -1]])
        for item in samples:
            f = item["frame"]
            assert np.array_equal(reloaded.get_traces(start_frame=f, end_frame=f + 1000),
                                  source.get_traces(start_frame=f, end_frame=f + 1000).astype("float32"))
        stage_capsule(root, arm, name, view_json, staged / "recordings" / name, pp_code, pp_params)
    provenance = {"session": rel, "group": group, "name": name, "dredge_archive_report": str(archive_report),
                  "archive_stage_report": str(staged / "stage_report.json"),
                  "original_ks4_pilot_recording": str(source_json), "dredge_corrected_recording": str(corrected_json),
                  "fixed_units": historic.unit_ids.tolist(), "fixed_sparsity": True,
                  "spikeinterface": si.__version__, "sample_checks": samples,
                  "postprocessing_code": str(pp_code), "curation_code": str(cur_code),
                  "postprocessing_params": pp_params, "curation_params": json.loads(cur_args),
                  "postprocessing_capsule_patch": {"before": PATCH_FROM, "after": PATCH_TO}}
    (root / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return root, name, pp_params, cur_code, cur_args


def run(user_root, index):
    root, name, params, cur_code, cur_args = prepare(user_root, index)
    run_postprocessing(root, name, params)
    heldout(root)
    for arm in ARMS:
        frozen.curation_command(root / arm, name, cur_code, cur_args)
    dredge_trace_models.check_models(user_root)
    print(json.dumps({"staged": str(root), "fixed_units": len(si.load(root / "fixed_sorting").unit_ids),
                      "postprocessing_and_stability": "passed"}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("run", "check-models"))
    parser.add_argument("--user-root", type=Path, required=True)
    parser.add_argument("--index", type=int, choices=range(20))
    args = parser.parse_args()
    if args.mode == "check-models":
        print(json.dumps(dredge_trace_models.check_models(args.user_root), indent=2), flush=True)
    else:
        assert args.index is not None
        run(args.user_root, args.index)
