#!/usr/bin/env python3
"""Read-only checks on gate inputs; does not stage or run any replay arm."""

import json
from pathlib import Path
import sys

import numpy as np
import spikeinterface as si

from dredge_trace_probe import TEST, source_paths
from dredge_trace_replay import sample_checks, validate_versions
import dredge_trace_models
import ks4_motion_trace_replay as frozen


def preflight(user_root):
    u, rel, pilot, _ = source_paths(user_root, 0)
    staged = u / TEST / "staged" / rel
    assert (staged / "stage_complete").read_text().strip() == "passed"
    validate_versions(pilot, staged)
    models = dredge_trace_models.check_models(u)
    name = "block0_imec0.ap_recording1_group0"
    pp, params = frozen.capsule_source(pilot / "work" / rel, "postprocessing", 0)
    a = pp.parent / "data" / f"binary_{name}.json"
    assert a.is_file(), a
    b = staged / "preprocessed" / f"{name}.json"
    original, corrected = (si.load(path, base_folder=path.parent) for path in (a, b))
    samples = sample_checks((original, corrected))
    analyzer = si.load_sorting_analyzer(staged / "postprocessed" / f"{name}.zarr", read_only=True)
    assert np.array_equal(analyzer.recording.channel_ids, corrected.channel_ids)
    assert analyzer.recording.get_num_frames() == corrected.get_num_frames()
    for check in samples:
        f = check["frame"]
        assert np.array_equal(analyzer.recording.get_traces(start_frame=f, end_frame=f + 1000),
                              corrected.get_traces(start_frame=f, end_frame=f + 1000))
    cur, cur_args = frozen.capsule_source(pilot / "work" / rel, "curation", 0)
    assert json.loads(params)["use_motion_corrected"] is False
    assert "unitrefine" in json.loads(cur_args)["noise_strategy"]
    print(json.dumps({"session": rel, "shank": name, "units": len(analyzer.unit_ids),
                      "sparsity_shape": analyzer.sparsity.mask.shape, "samples": samples,
                      "postprocessing_code": str(pp), "curation_code": str(cur),
                      "models": models, "preflight": "passed"}, indent=2), flush=True)


if __name__ == "__main__":
    preflight(Path(sys.argv[1]))
