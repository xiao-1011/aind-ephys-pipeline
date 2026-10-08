#!/usr/bin/env python3
"""Replay KS4 pilot postprocessing with its saved motion on non-whitened traces.

Run inside the pinned pipeline-base 1.4.0 image. Never writes to pilot sources.
"""

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

SESSIONS = (
    "cohort07/20260501/vr2220260501_g0",
    "cohort08/20260719/vr2520260719_g0",
    "cohort09/20260921/vr2820260921_g0",
    "cohort08/20260721/vr2320260721_g0",
)
PILOT = "baseline_pilots/ks4_followups_20261008_3526824"
TEST = "baseline_pilots/ks4_native_motion_trace_test_20261008"
INTERPOLATION = dict(border_mode="force_extrapolate", spatial_interpolation_method="kriging", sigma_um=20, p=2)


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def check_models(user_root):
    from huggingface_hub import HfApi
    state = json.loads((Path(user_root) / TEST / "model_provenance.json").read_text())
    for model in state.values():
        assert HfApi().model_info(model["repo"]).sha == model["revision"], f"Model revision changed: {model['repo']}"


def capsule_source(work, repo, group):
    candidates = []
    for command in work.glob("*/*/.command.sh"):
        text = command.read_text(errors="replace")
        if f"aind-ephys-{repo}" not in text:
            continue
        data = command.parent / "capsule/data"
        if not any(data.glob(f"postprocessed_*group{group}.zarr")) and repo == "curation":
            continue
        if repo == "postprocessing":
            jobs = list(data.glob("job_*.json"))
            if jobs and not any(json.loads(j.read_text())["recording_name"].endswith(f"group{group}") for j in jobs):
                continue
        matches = re.findall(r"^\s*\./run --params (.*)$", text, re.M)
        if matches:
            assert len(matches) == 1, f"Ambiguous replay command: {command}"
            args = shlex.split(matches[0])
            assert len(args) == 1, command
            candidates.append((command.parent / "capsule/code", args[0]))
    if not candidates:
        raise RuntimeError(f"No pinned {repo} capsule found in {work} for group {group}")
    # All copies of the postprocessing capsule must have the same parameters.
    assert len({args for _, args in candidates}) == 1, f"Inconsistent {repo} parameters"
    return candidates[0]


def link(path, source):
    assert source.exists(), source
    assert not path.exists() and not path.is_symlink(), path
    path.symlink_to(source.resolve(), target_is_directory=source.is_dir())


def setup(args):
    import numpy as np
    import spikeinterface as si
    import spikeinterface.preprocessing as spre
    from spikeinterface.sortingcomponents.motion import interpolate_motion

    check_models(args.user_root)
    u = Path(args.user_root)
    rel = SESSIONS[args.index // 4]
    group = args.index % 4
    name = f"block0_imec0.ap_recording1_group{group}"
    pilot = u / PILOT
    output = pilot / "outputs" / rel
    work = pilot / "work" / rel
    root = u / TEST / rel / f"group{group}"
    assert not root.exists(), f"Test directory already exists: {root}; inspect it before retrying"
    motion_folder = output / "spikesorted/motion" / name
    pp_code, pp_params = capsule_source(work, "postprocessing", group)
    cur_code, cur_params = capsule_source(work, "curation", group)
    assert json.loads(pp_params)["use_motion_corrected"] is False
    assert (output / "postprocessed" / f"{name}.zarr").is_dir()
    root.mkdir(parents=True)
    source_data = pp_code.parent / "data"
    source_binary = source_data / f"binary_{name}.json"
    assert source_binary.is_file()
    recording = si.load(source_binary, base_folder=source_data)
    original_analyzer = si.load_sorting_analyzer(output / "postprocessed" / f"{name}.zarr", read_only=True)
    original_analyzer.sorting.save(folder=root / "fixed_sorting")
    np.save(root / "fixed_sparsity.npy", original_analyzer.sparsity.mask)
    motion = si.Motion.load(motion_folder)
    assert motion.num_segments == recording.get_num_segments() == 1
    assert np.isfinite(motion.displacement[0]).all()
    rec_times = recording.get_times()
    bins = motion.temporal_bins_s[0]
    assert rec_times[0] <= bins[0] < bins[-1] <= rec_times[-1]
    assert (bins[0] - rec_times[0]) < 3 and (rec_times[-1] - bins[-1]) < 3
    corrected = interpolate_motion(spre.astype(recording, "float32"), motion=motion, **INTERPOLATION)
    assert corrected.get_channel_ids().tolist() == recording.get_channel_ids().tolist()
    assert corrected.get_num_frames() == recording.get_num_frames()
    # Validate that the recorded motion has a measurable effect, without touching
    # the source binary. The complete float32 trace is materialized below because
    # InterpolateMotionRecording cannot be serialized in SI 0.105.0.
    frames = [min(int(recording.sampling_frequency * s), recording.get_num_frames() - 100) for s in (30, 300, 600)]
    change = [float(np.max(np.abs(corrected.get_traces(start_frame=f, end_frame=f + 100) - recording.get_traces(start_frame=f, end_frame=f + 100)))) for f in frames]
    assert max(change) > 0, (rel, group, change)
    saved = corrected.save(format="binary", folder=root / "corrected_binary", chunk_duration="1s", n_jobs=min(int(os.environ.get("SLURM_CPUS_PER_TASK", "8")), 16), progress_bar=False)
    corrected_json = root / "corrected_recording.json"
    saved.dump(corrected_json)
    reloaded = si.load(corrected_json, base_folder=root)
    assert reloaded.get_num_frames() == recording.get_num_frames()
    assert np.array_equal(reloaded.get_times()[[0, -1]], rec_times[[0, -1]])
    assert np.array_equal(reloaded.get_channel_ids(), recording.get_channel_ids())
    assert all(np.array_equal(reloaded.get_traces(start_frame=f, end_frame=f + 100), corrected.get_traces(start_frame=f, end_frame=f + 100)) for f in frames)

    # Two arms use float32, identical surviving units, original channel masks,
    # and seeded waveform/noise sampling. No sorting or deduplication reruns.
    params = json.loads(pp_params)
    params["duplicate_threshold"] = None
    params["extensions"]["random_spikes"]["seed"] = 0
    params["extensions"]["noise_levels"]["random_slices_kwargs"]["seed"] = 0
    pp_params = json.dumps(params)
    replacement_from = "sorting=sorting, recording=recording_bin, sparse=True, return_in_uV=return_in_uV, **sparsity_params"
    replacement_to = "sorting=sorting, recording=recording_bin, sparsity=si.ChannelSparsity(np.load('../data/fixed_sparsity.npy'), unit_ids=sorting.unit_ids, channel_ids=recording_bin.channel_ids), return_in_uV=return_in_uV"
    for arm in ("uncorrected", "native_motion_interpolated"):
        pp = root / arm / "postprocessing/capsule"
        (pp / "data").mkdir(parents=True)
        (pp / "results").mkdir()
        (pp / "scratch").mkdir()
        shutil.copytree(pp_code, pp / "code")
        code_file = pp / "code/run_capsule.py"
        code = code_file.read_text()
        assert code.count(replacement_from) == 1, "Unexpected pinned capsule code"
        code_file.write_text(code.replace(replacement_from, replacement_to))
        if arm == "uncorrected":
            source = spre.astype(recording, "float32").save(format="binary", folder=root / "control_binary", chunk_duration="1s", n_jobs=16, progress_bar=False)
            arm_json = root / "control_recording.json"
            source.dump(arm_json)
            binary_folder = root / "control_binary"
        else:
            arm_json, binary_folder = corrected_json, root / "corrected_binary"
        link(pp / "data" / f"binary_{name}.json", arm_json)
        link(pp / "data" / f"preprocessed_{name}", binary_folder)
        link(pp / "data" / f"spikesorted_{name}", root / "fixed_sorting")
        link(pp / "data/fixed_sparsity.npy", root / "fixed_sparsity.npy")
    # Intentionally do NOT stage the original preprocessed_<name>.json: the
    # capsule would otherwise choose uncorrected lazy traces as the analyzer.
    meta = dict(session=rel, group=group, name=name, pilot=str(pilot), source_work=str(work),
                original_binary_json=str(source_binary.resolve()), motion_folder=str(motion_folder),
                motion_checksums={p.name: sha256(p) for p in motion_folder.glob("*.npy")},
                original_archive_report=str(pilot / "reports" / f"{rel.split('/')[-1]}.json"),
                motion_bins_s=[float(bins[0]), float(bins[-1])], trace_bins_s=[float(rec_times[0]), float(rec_times[-1])],
                interpolation=INTERPOLATION, corrected_dtype=str(reloaded.dtype),
                sample_max_difference=change, postprocessing_params=json.loads(pp_params),
                curation_params=json.loads(cur_params), postprocessing_capsule=str(pp_code),
                curation_capsule=str(cur_code), spikeinterface=si.__version__, fixed_units=original_analyzer.unit_ids.tolist(),
                fixed_sparsity=True, sampling_seed=0, postprocessing_capsule_patch=dict(before=replacement_from, after=replacement_to))
    (root / "provenance.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(dict(test=str(root), sample_max_difference=change), indent=2), flush=True)
    return root, name, pp_params, cur_code, cur_params


def run_postprocessing(root, name, pp_params):
    for arm in ("uncorrected", "native_motion_interpolated"):
        capsule = root / arm / "postprocessing/capsule"
        subprocess.run([sys.executable, "-u", "run_capsule.py", "--params", pp_params], cwd=capsule / "code", check=True)
        assert (capsule / "results" / f"postprocessed_{name}.zarr").is_dir()
        (root / arm / "postprocessing_complete").write_text("passed\n")


def curation_command(root, name, cur_code, cur_params):
    capsule = root / "curation/capsule"
    (capsule / "data").mkdir(parents=True)
    (capsule / "results").mkdir()
    (capsule / "scratch").mkdir()
    shutil.copytree(cur_code, capsule / "code")
    for stem in (f"postprocessed_{name}.zarr", f"data_process_postprocessing_{name}.json"):
        link(capsule / "data" / stem, root / "postprocessing/capsule/results" / stem)
    # Curation is run inside the checksummed SI #4830 image by the Slurm script.
    (root / "curation_params.json").write_text(cur_params)
    print(str(capsule), flush=True)


def stability(root, name):
    """Identical held-out spike samples in four time quarters, on fixed masks."""
    import pandas as pd
    import numpy as np
    import spikeinterface as si
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    sorting = si.load(root / "fixed_sorting")
    masks = np.load(root / "fixed_sparsity.npy")
    recs = {arm: si.load(root / filename, base_folder=root) for arm, filename in
            (("uncorrected", "control_recording.json"), ("native_motion_interpolated", "corrected_recording.json"))}
    rng = np.random.default_rng(1729)
    n = recs["uncorrected"].get_num_frames()
    before, after = 60, 90  # same 2 ms / 3 ms window as pipeline
    rows, examples = [], []
    for index, unit in enumerate(sorting.unit_ids):
        spikes = sorting.get_unit_spike_train(unit)
        channels = np.flatnonzero(masks[index])
        if channels.size == 0:
            continue
        frames = []
        for quarter in range(4):
            eligible = spikes[(spikes >= max(before, quarter * n // 4)) & (spikes < min(n - after, (quarter + 1) * n // 4))]
            frames.append(rng.choice(eligible, min(16, len(eligible)), replace=False))
        if any(len(f) < 8 for f in frames):
            continue
        templates = {}
        for arm, recording in recs.items():
            waves = np.stack([np.mean([recording.get_traces(start_frame=int(f) - before, end_frame=int(f) + after, channel_ids=recording.channel_ids[channels]) for f in fs], axis=0) for fs in frames])
            templates[arm] = waves
            flat = waves.reshape(4, -1)
            average = flat.mean(axis=0)
            cosine = flat @ average / (np.linalg.norm(flat, axis=1) * np.linalg.norm(average) + 1e-12)
            amplitude = np.max(np.abs(waves), axis=(1, 2))
            peak_channels = channels[np.max(np.abs(waves), axis=1).argmax(axis=1)]
            y = recording.get_channel_locations()[peak_channels, 1]
            rows.append(dict(unit_id=unit, trace=arm, temporal_template_cosine=float(cosine.mean()),
                             quarter_peak_amplitude_cv=float(amplitude.std() / (amplitude.mean() + 1e-12)),
                             quarter_peak_channel_range_um=float(np.ptp(y)), sampled_spikes=int(sum(map(len, frames)))))
        if len(examples) < 12:
            examples.append((unit, channels, templates))
    pd.DataFrame(rows, columns=("unit_id", "trace", "temporal_template_cosine", "quarter_peak_amplitude_cv", "quarter_peak_channel_range_um", "sampled_spikes")).to_csv(root / "heldout_waveform_stability.csv", index=False)
    if examples:
        fig, axes = plt.subplots(len(examples), 2, figsize=(10, 2 * len(examples)), squeeze=False)
        for row, (unit, channels, templates) in enumerate(examples):
            ref = templates["uncorrected"].mean(axis=0)
            channel = np.max(np.abs(ref), axis=0).argmax()
            for col, (arm, waves) in enumerate(templates.items()):
                for quarter, wave in enumerate(waves):
                    axes[row, col].plot(np.arange(-before, after) / 30, wave[:, channel], label=f"Q{quarter + 1}")
                axes[row, col].set_title(f"unit {unit}, {arm}, original channel {channels[channel]}")
        axes[0, 0].legend()
        fig.tight_layout()
        fig.savefig(root / "heldout_quarter_waveforms.png", dpi=120)
        plt.close(fig)


def results(args):
    import pandas as pd
    import numpy as np
    import spikeinterface as si
    u = Path(args.user_root)
    test = u / TEST
    rows = []
    for i in range(16):
        rel, group = SESSIONS[i // 4], i % 4
        root = test / rel / f"group{group}"
        name = f"block0_imec0.ap_recording1_group{group}"
        assert (root / "curation_complete").exists(), f"Incomplete {root}"
        old = u / PILOT / "outputs" / rel
        old_an = si.load_sorting_analyzer(root / "uncorrected/postprocessing/capsule/results" / f"postprocessed_{name}.zarr", read_only=True)
        new_an = si.load_sorting_analyzer(root / "native_motion_interpolated/postprocessing/capsule/results" / f"postprocessed_{name}.zarr", read_only=True)
        work = u / PILOT / "work" / rel
        old_code, _ = capsule_source(work, "curation", group)
        historical_labels = pd.read_csv(old_code.parent / "results" / f"unit_labels_{name}.csv")
        historical_labels.to_csv(root / "historical_unit_labels.csv", index=False)
        old_labels = pd.read_csv(root / "uncorrected/curation/capsule/results" / f"unit_labels_{name}.csv")
        new_labels = pd.read_csv(root / "native_motion_interpolated/curation/capsule/results" / f"unit_labels_{name}.csv")
        a, b = old_an.unit_ids, new_an.unit_ids
        assert len(a) == len(old_labels) and len(b) == len(new_labels)
        assert np.array_equal(a, b)
        assert np.array_equal(old_an.sorting.to_spike_vector(), new_an.sorting.to_spike_vector())
        before = old_labels.assign(unit_id=a).set_index("unit_id")
        after = new_labels.assign(unit_id=b).set_index("unit_id")
        common = before.index.intersection(after.index)
        for label, data in (("uncorrected", before), ("native_motion_interpolated", after)):
            counts = dict(units=len(data), qc_pass=int(data.default_qc.sum()),
                          sua=int((data.unitrefine_label == "sua").sum()),
                          sua_qc_pass=int(((data.unitrefine_label == "sua") & data.default_qc).sum()))
            rows.append(dict(session=rel, group=group, trace=label, **counts,
                             common_units=len(common),
                             changed_qc=int((before.loc[common, "default_qc"] != after.loc[common, "default_qc"]).sum()),
                             changed_unitrefine=int((before.loc[common, "unitrefine_label"] != after.loc[common, "unitrefine_label"]).sum()),
                             sua_gained=int(((before.loc[common, "unitrefine_label"] != "sua") & (after.loc[common, "unitrefine_label"] == "sua")).sum()),
                             sua_lost=int(((before.loc[common, "unitrefine_label"] == "sua") & (after.loc[common, "unitrefine_label"] != "sua")).sum())))
        # Machine-readable unit-level matched data; don't mistake a changed
        # postprocessing deduplication decision for a changed KS4 sorting.
        metrics = []
        for analyzer, label in ((old_an, "uncorrected"), (new_an, "native_motion_interpolated")):
            df = analyzer.get_extension("quality_metrics").get_data().copy()
            df.index.name = "unit_id"
            df = df.reset_index()
            df["trace"] = label
            df["session"] = rel
            df["group"] = group
            metrics.append(df)
        unit_labels = pd.concat([before.assign(trace="uncorrected"), after.assign(trace="native_motion_interpolated")])
        unit_labels.index.name = "unit_id"
        unit_labels.to_csv(root / "unit_labels_comparison.csv")
        pd.concat(metrics, ignore_index=True).to_csv(root / "quality_metrics_comparison.csv", index=False)
    with (test / "comparison.csv").open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    summaries = []
    for rel in SESSIONS:
        frames = [pd.read_csv(test / rel / f"group{g}" / "heldout_waveform_stability.csv") for g in range(4)]
        changes, amplitude_changes, channel_changes = [], [], []
        for df in frames:
            if df.empty:
                continue
            before = df[df.trace == "uncorrected"].set_index("unit_id")
            after = df[df.trace == "native_motion_interpolated"].set_index("unit_id")
            delta = after.temporal_template_cosine - before.temporal_template_cosine
            changes.extend(delta.tolist())
            amplitude_changes.extend((after.quarter_peak_amplitude_cv - before.quarter_peak_amplitude_cv).tolist())
            channel_changes.extend((after.quarter_peak_channel_range_um - before.quarter_peak_channel_range_um).tolist())
        summaries.append(dict(session=rel, eligible_units=len(changes),
                              median_temporal_cosine_change=float(np.median(changes)) if changes else None,
                              median_quarter_amplitude_cv_change=float(np.median(amplitude_changes)) if changes else None,
                              median_quarter_peak_channel_range_change_um=float(np.median(channel_changes)) if changes else None,
                              fraction_temporal_cosine_improved=float(np.mean(np.asarray(changes) > 0)) if changes else None))
    (test / "waveform_stability_summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
    report = ["# KS4 trace sensitivity test", "", "KS4 sorting, surviving unit IDs, channel masks, and seeded sampling held fixed.",
              "Only analyzer input changes: float32 non-whitened uncorrected versus SI interpolation using saved KS4 motion.",
              "Interpolation is not claimed to reproduce KS4's internal whitening/interpolation order.", "", "## Session totals", "",
              "| Session | Trace | Units | QC | SUA | SUA + QC |", "|---|---|---:|---:|---:|---:|"]
    for rel in SESSIONS:
        for arm in ("uncorrected", "native_motion_interpolated"):
            subset = [r for r in rows if r["session"] == rel and r["trace"] == arm]
            totals = [sum(r[k] for r in subset) for k in ("units", "qc_pass", "sua", "sua_qc_pass")]
            report.append(f"| {rel.split('/')[-1]} | {arm} | " + " | ".join(map(str, totals)) + " |")
    report += ["", "## Held-out temporal waveform consistency", "", "Positive cosine changes mean more consistent four-quarter average waveforms, not proven sorting accuracy.",
               "```json", json.dumps(summaries, indent=2), "```", "", "## Decision guardrail", "",
               "Do not promote an analysis trace solely because QC/SUA counts rise. Review the per-unit metric/label changes and quarter-waveform plots, including border channels and gain/loss examples. Existing archives are unchanged; full baseline batch has not been launched.",
               "The initial fixed channel masks are those of the historical uncorrected analyzer; this is an isolated trace sensitivity test, not a new end-to-end benchmark. A production corrected analyzer may need its own sparsity/deduplication validation."]
    (test / "REPORT.md").write_text("\n".join(report) + "\n")
    print(json.dumps(rows, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("run", "report", "check-models"))
    parser.add_argument("--user-root", required=True)
    parser.add_argument("--index", type=int, choices=range(16))
    arguments = parser.parse_args()
    if arguments.mode == "run":
        assert arguments.index is not None
        run_postprocessing(*setup(arguments)[:3])
        root = Path(arguments.user_root) / TEST / SESSIONS[arguments.index // 4] / f"group{arguments.index % 4}"
        meta = json.loads((root / "provenance.json").read_text())
        stability(root, meta["name"])
        # The orchestration script invokes curation in its own pinned image.
        for arm in ("uncorrected", "native_motion_interpolated"):
            curation_command(root / arm, meta["name"], Path(meta["curation_capsule"]), json.dumps(meta["curation_params"]))
    elif arguments.mode == "report":
        check_models(arguments.user_root)
        results(arguments)
    else:
        check_models(arguments.user_root)
