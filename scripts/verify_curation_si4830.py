#!/usr/bin/env python3
"""Compare stock/patched UnitRefine and replay a retained curation task in isolation.

Orchestrated by verify_curation_si4830.sh. Source analyzers are read-only; copied
inputs use absolute recording references to the retained work tree for this test.
"""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import shlex
import shutil
import subprocess

from archive_session import atomic_json, digest, require
from apply_si4830 import ORIGINAL_SHA256, PATCHED_SHA256, SOURCE


def inventory(root):
    return {str(p.relative_to(root)): digest(p) for p in sorted(root.rglob("*")) if p.is_file()}


def task_params(task):
    commands = [shlex.split(line.strip()) for line in (task / ".command.sh").read_text().splitlines()
                if line.strip().startswith("./run ")]
    require(len(commands) == 1 and commands[0][:2] == ["./run", "--params"]
            and len(commands[0]) == 3, "Expected one capsule invocation with JSON --params")
    return json.loads(commands[0][2])


def load_analyzer(path):
    import spikeinterface as si

    analyzer = si.load_sorting_analyzer(path, load_extensions=True, read_only=True)
    require(analyzer.recording is not None, f"Recording failed to load: {path}")
    return analyzer


def prepare(args):
    from spikeinterface.core.core_tools import check_json
    from huggingface_hub import snapshot_download
    import zarr

    out, task = args.output, args.task.resolve()
    capsule = out / "capsule"
    capsule.mkdir()  # Fail rather than overwrite a previous verification.
    shutil.copytree(task / "capsule/code", capsule / "code")
    for name in ("data", "results", "scratch"):
        (capsule / name).mkdir()
    original = task_params(task)
    atomic_json(out / "params_original.json", original)
    params = deepcopy(original)
    model_info = {}
    for key, repo in params["unitrefine"].items():
        require(key in ("noise_neural_classifier", "sua_mua_classifier") and repo,
                "This verification requires both configured UnitRefine models")
        snapshot = Path(snapshot_download(repo_id=repo)).resolve()
        target = out / "models" / key
        shutil.copytree(snapshot, target)
        params["unitrefine"][key] = str(target)
        model_info[key] = {"repo": repo, "revision": snapshot.name, "snapshot": str(snapshot),
                           "files": inventory(target)}
    atomic_json(out / "params_frozen_models.json", params)
    sources = {}
    for p in sorted((task / "capsule/data").iterdir()):
        source, target = p.resolve(), capsule / "data" / p.name
        if p.name.startswith("postprocessed_") and p.suffix == ".zarr":
            require("failed" not in sources, "Expected a single-shank curation task")
            analyzer = load_analyzer(source)
            sources["failed"] = str(source)
            shutil.copytree(source, target)
            group = zarr.open(str(target), mode="a")
            group["recording"][0] = check_json(analyzer.recording.to_dict(recursive=True))
            zarr.consolidate_metadata(group.store)
            copied = load_analyzer(target)
            require(copied.get_num_units() == analyzer.get_num_units(), "Copied analyzer unit count changed")
        elif source.is_file():
            shutil.copy2(source, target)
        else:
            raise RuntimeError(f"Unexpected task input: {p}")
    require("failed" in sources, "No failed analyzer input")
    sources["reference"] = str(args.reference.resolve())
    require(sources["reference"] != sources["failed"], "Reference must be a different analyzer")
    load_analyzer(args.reference)
    state = {"sources": sources, "source_files": {k: inventory(Path(v)) for k, v in sources.items()},
             "task": str(task), "models": model_info, "code_files": inventory(capsule / "code"),
             "copied_analyzer": str(next((capsule / "data").glob("postprocessed_*.zarr")))}
    atomic_json(out / "inputs.json", state)
    print("Prepared isolated task with frozen model snapshots and copied analyzer", flush=True)


def diagnose(analyzer, formatter):
    import numpy as np

    metrics = analyzer.get_metrics_extension_data().select_dtypes(include=[np.number])
    formatted = formatter(metrics)
    affected = []
    for column in metrics:
        values = metrics[column].to_numpy()
        invalid = (~np.isnan(values)) & formatted[column].isna().to_numpy()
        for unit in metrics.index[invalid]:
            value = metrics.loc[unit, column]
            spikes = sum(len(analyzer.sorting.get_unit_spike_train(unit, segment_index=s))
                         for s in range(analyzer.sorting.get_num_segments()))
            affected.append({"unit_id": unit.item() if isinstance(unit, np.generic) else unit,
                             "metric": column, "original_value": repr(float(value)), "num_spikes": spikes,
                             "reason": "existing_infinity" if np.isinf(value) else "float32_overflow"})
    return affected


def predict(args):
    from importlib import metadata
    import numpy as np
    import pandas as pd
    import spikeinterface.curation as scur
    from spikeinterface.curation.model_based_curation import _format_metric_dataframe

    out = args.output
    state = json.loads((out / "inputs.json").read_text())
    params = json.loads((out / "params_frozen_models.json").read_text())
    source = Path(metadata.distribution("spikeinterface").locate_file(SOURCE))
    expected = ORIGINAL_SHA256 if args.phase == "baseline" else PATCHED_SHA256
    require(digest(source) == expected, f"Wrong SI source loaded for {args.phase}")
    packages = sorted([d.metadata["Name"], d.version] for d in metadata.distributions())
    provenance = json.loads((out / "image_provenance.json").read_text())
    require(packages == provenance["packages"], f"Package versions differ from the base image in {args.phase}")
    summary = {}
    for role in ("reference", "failed"):
        analyzer = load_analyzer(state["sources"][role])
        metrics_before = analyzer.get_metrics_extension_data().copy(deep=True)
        try:
            labels = scur.unitrefine_label_units(analyzer, **params["unitrefine"])
        except ValueError as exc:
            if args.phase != "baseline" or role != "failed" or "infinity or a value too large" not in str(exc):
                raise
            summary[role] = {"expected_overflow_reproduced": True, "error": str(exc)}
            print(f"Stock image reproduced the original failure: {exc}", flush=True)
        else:
            require(not (args.phase == "baseline" and role == "failed"), "Stock image did not reproduce the expected failure")
            require(len(labels) == analyzer.get_num_units(), f"Missing labels: {role}")
            require(set(labels["unitrefine_label"]) <= {"noise", "mua", "sua"}, "Unexpected classifier labels")
            probability = labels["unitrefine_probability"].to_numpy(dtype=float)
            require(np.isfinite(probability).all() and ((0 <= probability) & (probability <= 1)).all(),
                    "Invalid classification probabilities")
            labels.to_pickle(out / f"{args.phase}_{role}.pkl")
            labels.to_csv(out / f"{args.phase}_{role}.csv")
            if args.phase == "patched" and role == "reference":
                pd.testing.assert_frame_equal(labels, pd.read_pickle(out / "baseline_reference.pkl"), check_exact=True)
            summary[role] = {"units": len(labels),
                             "counts": {str(k): int(v) for k, v in labels["unitrefine_label"].value_counts().items()}}
            if args.phase == "patched":
                summary[role]["sanitized_metrics"] = diagnose(analyzer, _format_metric_dataframe)
        pd.testing.assert_frame_equal(metrics_before, analyzer.get_metrics_extension_data(), check_exact=True)
    if args.phase == "patched":
        require(any(v["reason"] == "float32_overflow" for v in summary["failed"]["sanitized_metrics"]),
                "No float32 overflow diagnosed in the problematic input")
    atomic_json(out / f"{args.phase}.json", summary)
    print(f"{args.phase}: {summary}", flush=True)


def capsule(args):
    import pandas as pd
    from huggingface_hub import HfApi

    out = args.output
    state = json.loads((out / "inputs.json").read_text())
    require((out / "baseline.json").exists() and (out / "patched.json").exists(), "Prediction checks incomplete")
    # Capsule 409a9a5 calls list_repo_files(repo_id=...) even when model files
    # have been cached, so HF_HUB_OFFLINE blocks it. Allow the metadata request
    # but fail if a model's upstream revision differs from the frozen snapshot.
    def check_model_revisions():
        for model in state["models"].values():
            require(HfApi().model_info(model["repo"]).sha == model["revision"],
                    f"Model changed since baseline: {model['repo']}")

    check_model_revisions()
    # Capsule 409a9a5 uses repo_id= even when checking model requirements. Keep its
    # original identifiers; the shell enables HF_HUB_OFFLINE after snapshotting,
    # so these resolve to the same frozen models used by the prediction checks.
    params = out / "params_original.json"
    with (out / "capsule.log").open("w") as log:
        subprocess.run(["bash", "run", "--params", str(params)], cwd=out / "capsule/code",
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    check_model_revisions()
    results = out / "capsule/results"
    csv_files = list(results.glob("unit_labels_*.csv"))
    require(len(csv_files) == 1, "Missing classifier output")
    labels = pd.read_csv(csv_files[0])
    expected = pd.read_pickle(out / "patched_failed.pkl")
    name = csv_files[0].name.removeprefix("unit_labels_").removesuffix(".csv")
    curation = json.loads((results / f"curation_{name}.json").read_text())
    require(curation["unit_ids"] == expected.index.tolist(), "Curation unit IDs differ")
    labels.index = pd.Index(curation["unit_ids"])
    pd.testing.assert_frame_equal(labels[expected.columns], expected, check_dtype=False,
                                  check_names=False, check_exact=False, rtol=1e-14, atol=0)
    process = json.loads((results / f"data_process_curation_{name}.json").read_text())
    require(process["output_parameters"]["total_units"] == len(expected), "Incomplete curation process output")
    for role, source in state["sources"].items():
        require(inventory(Path(source)) == state["source_files"][role], f"Source analyzer changed: {role}")
    require(inventory(out / "capsule/code") == state["code_files"], "Capsule code changed")
    for key, model in state["models"].items():
        require(inventory(out / "models" / key) == model["files"], "Frozen model files changed")
        require(inventory(Path(model["snapshot"])) == model["files"], "Capsule model snapshot differs")
    report = {"status": "passed", "source_task": state["task"], "source_analyzers_unchanged": True,
              "reference_predictions_identical": True, "stock_failure_reproduced": True,
              "patched": json.loads((out / "patched.json").read_text()),
              "curation_outputs": process["output_parameters"], "results": str(results),
              "image": json.loads((out / "image_provenance.json").read_text())}
    atomic_json(out / "verification.json", report)
    print("VERIFICATION PASSED: original failure reproduced, patched UnitRefine and full curation succeeded; reference predictions identical", flush=True)
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "baseline", "patched", "capsule"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--task", type=Path)
    parser.add_argument("--reference", type=Path)
    args = parser.parse_args()
    args.output = args.output.resolve()
    try:
        if args.phase == "prepare":
            require(args.task and args.reference, "prepare requires --task and --reference")
            prepare(args)
        elif args.phase in ("baseline", "patched"):
            predict(args)
        else:
            capsule(args)
    except Exception as exc:
        atomic_json(args.output / "verification.json", {"status": "failed", "phase": args.phase, "error": str(exc)})
        raise
