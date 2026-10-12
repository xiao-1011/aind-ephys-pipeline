#!/usr/bin/env python3
"""Read-only comparison of a saved replay binary and live SI interpolation.

Use only on compute nodes. This does not modify the frozen replay or pilot data.
"""

import argparse
import json
from pathlib import Path
import sys

import numpy as np
import spikeinterface as si
import spikeinterface.preprocessing as spre
from spikeinterface.sortingcomponents.motion import interpolate_motion


def compare(saved, live):
    assert saved.shape == live.shape
    finite_saved, finite_live = np.isfinite(saved), np.isfinite(live)
    both = finite_saved & finite_live
    delta = np.abs(saved[both].astype("float64") - live[both].astype("float64"))
    bad = both & (saved != live)
    channel_counts = bad.sum(axis=0)
    top = np.argsort(channel_counts)[-5:][::-1]
    return {
        "shape": list(saved.shape),
        "saved_dtype": str(saved.dtype), "live_dtype": str(live.dtype),
        "saved_nonfinite": int((~finite_saved).sum()), "live_nonfinite": int((~finite_live).sum()),
        "finite_mismatch": int(bad.sum()),
        "nonfinite_position_mismatch": int(np.logical_xor(finite_saved, finite_live).sum()),
        "exact": bool(np.array_equal(saved, live)),
        "equal_nan": bool(np.array_equal(saved, live, equal_nan=True)),
        "max_abs_difference": float(delta.max()) if delta.size else None,
        "p99_abs_difference": float(np.quantile(delta, 0.99)) if delta.size else None,
        "worst_channels": [[int(i), int(channel_counts[i])] for i in top],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    parser.add_argument("--group", type=int, choices=(0, 1, 2, 3), required=True)
    args = parser.parse_args()
    u, group = args.user_root.resolve(), args.group
    test = u / "baseline_pilots/ks4_native_motion_trace_test_20261008"
    sys.path.insert(0, str(test / "source"))
    from ks4_motion_trace_replay import INTERPOLATION, PILOT, capsule_source

    rel = "cohort08/20260719/vr2520260719_g0"
    name = f"block0_imec0.ap_recording1_group{group}"
    pilot = u / PILOT
    work = pilot / "work" / rel
    output = pilot / "outputs" / rel
    data = capsule_source(work, "postprocessing", group)[0].parent / "data"
    original = si.load(data / f"binary_{name}.json", base_folder=data)
    motion = si.Motion.load(output / "spikesorted/motion" / name)
    live = interpolate_motion(spre.astype(original, "float32"), motion=motion, **INTERPOLATION)
    root = test / rel / f"group{group}"
    assert (root / "corrected_recording.json").is_file()
    saved = si.load(root / "corrected_recording.json", base_folder=root)
    assert np.array_equal(original.channel_ids, saved.channel_ids)
    assert original.get_num_frames() == saved.get_num_frames()
    frames = [min(int(original.sampling_frequency * s), original.get_num_frames() - 100) for s in (30, 300, 600)]
    print(json.dumps({"group": group, "sampling_frequency": original.sampling_frequency,
                      "channels": original.get_num_channels(), "frames": original.get_num_frames(),
                      "times": [float(original.get_times()[i]) for i in (0, -1)],
                      "motion_bins": [float(motion.temporal_bins_s[0][i]) for i in (0, -1)]}), flush=True)
    for f in frames:
        a = saved.get_traces(start_frame=f, end_frame=f + 100)
        b = live.get_traces(start_frame=f, end_frame=f + 100)
        repeat = live.get_traces(start_frame=f, end_frame=f + 100)
        # Compare the same frames requested with more context; a saved trace
        # was calculated in 1-second chunks, not 100-frame windows.
        start = max(0, f - 15000)
        contextual = live.get_traces(start_frame=start, end_frame=min(f + 15000, original.get_num_frames()))
        core = contextual[f - start:f - start + 100]
        print(json.dumps({"frame": f, "direct": compare(a, b),
                          "repeat_direct": compare(b, repeat),
                          "contextual": compare(a, core)}), flush=True)
    for second in (30, 300, 600):
        f = min(int(original.sampling_frequency * second), original.get_num_frames() - 30000)
        start = max(0, f - 1000)
        stop = min(f + 1000, original.get_num_frames())
        a = saved.get_traces(start_frame=start, end_frame=stop)
        b = live.get_traces(start_frame=start, end_frame=stop)
        print(json.dumps({"boundary_frame": f, "boundary_window": [start, stop],
                          "comparison": compare(a, b)}), flush=True)


if __name__ == "__main__":
    main()
