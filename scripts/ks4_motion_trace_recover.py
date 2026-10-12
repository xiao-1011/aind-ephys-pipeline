#!/usr/bin/env python3
"""Complete only replay indices 5/6 using their retained corrected binaries.

Never overwrite a completed shank or the frozen replay source. Run on a CPU
compute node in the original pipeline-base image, with pilot sources read-only.
"""

import argparse
import json
from pathlib import Path
import shutil
import sys

import numpy as np
import spikeinterface as si
import spikeinterface.preprocessing as spre
from spikeinterface.sortingcomponents.motion import interpolate_motion


def verify_saved(saved, live, original):
    assert saved.dtype == np.dtype("float32")
    assert saved.get_num_segments() == live.get_num_segments() == 1
    assert saved.get_num_frames() == live.get_num_frames() == original.get_num_frames()
    assert np.array_equal(saved.channel_ids, original.channel_ids)
    assert np.array_equal(saved.get_times()[[0, -1]], original.get_times()[[0, -1]])
    n = original.get_num_frames()
    rng = np.random.default_rng(4830)
    frames = [min(int(original.sampling_frequency * s), n - 100) for s in (30, 300, 600)]
    frames += [100, n - 200] + rng.integers(100, n - 200, size=20).tolist()
    maximum = 0.0
    for frame in frames:
        start, end = max(0, frame - 1000), min(n, frame + 1100)
        saved_window = saved.get_traces(start_frame=start, end_frame=end)
        direct_window = live.get_traces(start_frame=start, end_frame=end)
        assert np.isfinite(saved_window).all() and np.isfinite(direct_window).all(), (frame, "nonfinite")
        a = saved_window[frame - start:frame - start + 100]
        b = direct_window[frame - start:frame - start + 100]
        assert np.array_equal(a, b), (frame, float(np.max(np.abs(a - b))))
        maximum = max(maximum, float(np.max(np.abs(a - original.get_traces(start_frame=frame, end_frame=frame + 100)))))
    assert maximum > 0, "Saved motion had no measurable trace effect"
    return {"exact_contextual_windows": len(frames), "max_change_from_uncorrected": maximum}


def recover(user_root, index, offline_model_check=False):
    u = user_root.resolve()
    test = u / "baseline_pilots/ks4_native_motion_trace_test_20261008"
    sys.path.insert(0, str(test / "source"))
    import ks4_motion_trace_replay as frozen

    if offline_model_check:
        from ks4_motion_trace_models import check_models
        check_models(u)
    else:
        frozen.check_models(u)
    rel, group = frozen.SESSIONS[index // 4], index % 4
    assert rel == "cohort08/20260719/vr2520260719_g0" and group in (1, 2)
    name = f"block0_imec0.ap_recording1_group{group}"
    pilot = u / frozen.PILOT
    output, work = pilot / "outputs" / rel, pilot / "work" / rel
    root = test / rel / f"group{group}"
    corrected_folder, corrected_json = root / "corrected_binary", root / "corrected_recording.json"
    for required in (corrected_folder / "traces_cached_seg0.raw", corrected_json,
                     root / "fixed_sorting", root / "fixed_sparsity.npy"):
        assert required.exists(), required
    for absent in (root / "curation_complete", root / "provenance.json", root / "control_binary",
                   root / "uncorrected", root / "native_motion_interpolated"):
        assert not absent.exists() and not absent.is_symlink(), f"Inspect before recovery: {absent}"
    code, params_string = frozen.capsule_source(work, "postprocessing", group)
    cur_code, cur_params = frozen.capsule_source(work, "curation", group)
    pp_params = json.loads(params_string)
    assert pp_params["use_motion_corrected"] is False
    source_data = code.parent / "data"
    binary_json = source_data / f"binary_{name}.json"
    assert binary_json.is_file()
    original = si.load(binary_json, base_folder=source_data)
    historical = si.load_sorting_analyzer(output / "postprocessed" / f"{name}.zarr", read_only=True)
    fixed = si.load(root / "fixed_sorting")
    mask = np.load(root / "fixed_sparsity.npy")
    assert np.array_equal(historical.unit_ids, fixed.unit_ids)
    assert np.array_equal(historical.sparsity.mask, mask)
    assert np.array_equal(historical.sorting.to_spike_vector(), fixed.to_spike_vector())
    motion_folder = output / "spikesorted/motion" / name
    motion = si.Motion.load(motion_folder)
    assert motion.num_segments == 1 and np.isfinite(motion.displacement[0]).all()
    times = original.get_times()
    bins = motion.temporal_bins_s[0]
    assert times[0] <= bins[0] < bins[-1] <= times[-1]
    assert bins[0] - times[0] < 3 and times[-1] - bins[-1] < 3
    live = interpolate_motion(spre.astype(original, "float32"), motion=motion, **frozen.INTERPOLATION)
    saved = si.load(corrected_json, base_folder=root)
    checks = verify_saved(saved, live, original)
    # Hash the retained 20 GB binary before staging any new files. Do not write
    # into corrected_folder; the partial attempt and all completed shanks remain.
    binary_sha256 = frozen.sha256(corrected_folder / "traces_cached_seg0.raw")
    pp_params["duplicate_threshold"] = None
    pp_params["extensions"]["random_spikes"]["seed"] = 0
    pp_params["extensions"]["noise_levels"]["random_slices_kwargs"]["seed"] = 0
    replacement_from = "sorting=sorting, recording=recording_bin, sparse=True, return_in_uV=return_in_uV, **sparsity_params"
    replacement_to = "sorting=sorting, recording=recording_bin, sparsity=si.ChannelSparsity(np.load('../data/fixed_sparsity.npy'), unit_ids=sorting.unit_ids, channel_ids=recording_bin.channel_ids), return_in_uV=return_in_uV"
    for arm in ("uncorrected", "native_motion_interpolated"):
        pp = root / arm / "postprocessing/capsule"
        (pp / "data").mkdir(parents=True)
        (pp / "results").mkdir()
        (pp / "scratch").mkdir()
        shutil.copytree(code, pp / "code")
        code_file = pp / "code/run_capsule.py"
        source_code = code_file.read_text()
        assert source_code.count(replacement_from) == 1, "Unexpected pinned capsule code"
        code_file.write_text(source_code.replace(replacement_from, replacement_to))
        if arm == "uncorrected":
            control = spre.astype(original, "float32").save(format="binary", folder=root / "control_binary",
                                                                chunk_duration="1s", n_jobs=16, progress_bar=False)
            arm_json, binary_folder = root / "control_recording.json", root / "control_binary"
            control.dump(arm_json)
        else:
            arm_json, binary_folder = corrected_json, corrected_folder
        frozen.link(pp / "data" / f"binary_{name}.json", arm_json)
        frozen.link(pp / "data" / f"preprocessed_{name}", binary_folder)
        frozen.link(pp / "data" / f"spikesorted_{name}", root / "fixed_sorting")
        frozen.link(pp / "data/fixed_sparsity.npy", root / "fixed_sparsity.npy")
    provenance = dict(session=rel, group=group, name=name, pilot=str(pilot), source_work=str(work),
                      original_binary_json=str(binary_json.resolve()), motion_folder=str(motion_folder),
                      motion_checksums={p.name: frozen.sha256(p) for p in motion_folder.glob("*.npy")},
                      motion_bins_s=[float(bins[0]), float(bins[-1])],
                      trace_bins_s=[float(times[0]), float(times[-1])],
                      interpolation=frozen.INTERPOLATION, corrected_dtype=str(saved.dtype),
                      postprocessing_params=pp_params, curation_params=json.loads(cur_params),
                      postprocessing_capsule=str(code), curation_capsule=str(cur_code),
                      spikeinterface=si.__version__, fixed_units=historical.unit_ids.tolist(),
                      fixed_sparsity=True, sampling_seed=0,
                      postprocessing_capsule_patch=dict(before=replacement_from, after=replacement_to),
                      recovery=dict(reason="100-frame edge-channel rounding; contextual trace check exactly matches",
                                    retained_corrected_binary_sha256=binary_sha256, **checks))
    (root / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    frozen.run_postprocessing(root, name, json.dumps(pp_params))
    frozen.stability(root, name)
    for arm in ("uncorrected", "native_motion_interpolated"):
        frozen.curation_command(root / arm, name, cur_code, cur_params)
    assert frozen.sha256(corrected_folder / "traces_cached_seg0.raw") == binary_sha256, "Corrected binary changed"
    print(json.dumps({"recovered": str(root), "checks": checks, "corrected_sha256": binary_sha256}), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    parser.add_argument("--index", type=int, choices=(5, 6), required=True)
    parser.add_argument("--offline-model-check", action="store_true", help="Verify pinned snapshots and hashes instead of querying Hugging Face HEAD")
    args = parser.parse_args()
    recover(args.user_root, args.index, offline_model_check=args.offline_model_check)
