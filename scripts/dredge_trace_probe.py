#!/usr/bin/env python3
"""Inspect five verified DREDGE tar manifests without extracting trace bytes."""

import argparse
import json
from pathlib import Path
import tarfile


SESSIONS = (
    "cohort06/20260318/vr1520260318_g0",
    "cohort07/20260501/vr2220260501_g0",
    "cohort08/20260719/vr2520260719_g0",
    "cohort09/20260921/vr2820260921_g0",
    "cohort08/20260721/vr2320260721_g0",
)
TEST = "baseline_pilots/dredge100_original_trace_20261009"
INITIAL = "baseline_pilots/20261008_ks4_builtin64_vr1520260318_g0_ce4972d"
FOLLOWUPS = "baseline_pilots/ks4_followups_20261008_3526824"
BATCH = "batch_runs/20261006_180017"


def source_paths(user_root, index):
    u = Path(user_root).resolve()
    rel = SESSIONS[index]
    pilot = u / (INITIAL if index == 0 else FOLLOWUPS)
    report = (u / BATCH / "recovery_si4830_3513952/archive_report.json" if index == 4
              else u / BATCH / "reports" / (rel.split("/")[-1] + ".json"))
    return u, rel, pilot, report


def inspect(user_root, index):
    u, rel, pilot, report_file = source_paths(user_root, index)
    root = u / TEST
    report = json.loads(report_file.read_text())
    archive = Path(report["archive"])
    name = rel.split("/")[-1]
    assert report["verified"] is True and report["session"].endswith(name)
    assert archive == u / "session_archives" / rel.split("/")[0] / rel.split("/")[1] / (name + ".tar")
    assert archive.is_file() and archive.stat().st_size == report["size"]
    assert len(report["sha256"]) == 64 and len(report["shanks"]) == 4
    assert all((pilot / "outputs" / rel / "preprocessed" / f"{shank}.json").is_file()
               for shank in report["shanks"]), "Missing original lazy KS4 pilot recording"
    with tarfile.open(archive, "r:") as tar:
        manifest_file = tar.extractfile(f"{name}/archive_manifest.json")
        assert manifest_file is not None
        manifest = json.load(manifest_file)
        assert manifest["session"] == name and manifest["shanks"] == report["shanks"]
        assert all(tar.getmember(f"{name}/{sub}").isfile()
                   for sub in ("archive_provenance/active_params.json", "archive_provenance/capsule_versions.env"))
        params = json.load(tar.extractfile(f"{name}/archive_provenance/active_params.json"))
        assert params["preprocessing"]["motion_correction"]["compute"] is True
        assert params["preprocessing"]["motion_correction"]["apply"] is True
        assert params["spikesorting"]["kilosort4"]["skip_motion_correction"] is True
        pilot_config = pilot / ("source/pipeline/active_params.json" if index == 0
                                else "source/pipeline/active_params.json")
        if not pilot_config.is_file():
            pilot_config = pilot / "snapshot/pipeline/active_params.json"
        assert pilot_config.is_file(), pilot_config
        native = json.loads(pilot_config.read_text())
        assert native["preprocessing"]["motion_correction"]["compute"] is False
        assert native["preprocessing"]["motion_correction"]["apply"] is False
        assert native["spikesorting"]["kilosort4"]["skip_motion_correction"] is False
        for key, expected in (("compute", False), ("apply", False)):
            params["preprocessing"]["motion_correction"][key] = expected
        params["spikesorting"]["kilosort4"]["skip_motion_correction"] = False
        assert params == native, "Other pipeline parameters differ; cannot borrow native lazy original traces"
        files = manifest["files"]
        groups = {}
        for shank in report["shanks"]:
            prefixes = (f"recordings/{shank}/", f"postprocessed/{shank}.zarr/")
            keys = [k for k in files if k.startswith(prefixes)]
            assert any(k.startswith(prefixes[0]) for k in keys) and any(k.startswith(prefixes[1]) for k in keys)
            assert f"preprocessed/{shank}.json" in files
            groups[shank] = {"files": len(keys), "gigabytes": round(sum(files[k]["size"] for k in keys) / 1e9, 3),
                             "dredge_units": report["shanks"][shank]}
        info = {"session": rel, "archive": str(archive), "archive_sha256": report["sha256"],
                "report": str(report_file), "pilot": str(pilot), "total_archive_files": len(files),
                "selected_files": sum(g["files"] for g in groups.values()), "groups": groups,
                "version_info": tar.extractfile(f"{name}/archive_provenance/capsule_versions.env").read().decode()}
    output = root / "inventory" / (name + ".json")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as handle:
        json.dump(info, handle, indent=2)
        handle.write("\n")
    print(json.dumps(info, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    parser.add_argument("--index", type=int, choices=range(5), required=True)
    args = parser.parse_args()
    inspect(args.user_root, args.index)
