#!/usr/bin/env python3
"""Stage only five-session DREDGE analyzer/trace inputs, verifying tar file hashes.

No source archive or batch directory is modified; partial stages remain on
failure for inspection rather than being overwritten on a retry.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile

from dredge_trace_probe import TEST, source_paths


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def selected_files(manifest):
    shanks = tuple(manifest["shanks"])
    assert len(shanks) == 4 and all(x.startswith("block0_imec0.ap_recording1_group") for x in shanks)
    files = manifest["files"]
    selected = {"archive_provenance/active_params.json", "archive_provenance/capsule_versions.env"}
    for shank in shanks:
        selected.add(f"preprocessed/{shank}.json")
        for key in files:
            if key.startswith((f"recordings/{shank}/", f"postprocessed/{shank}.zarr/")):
                selected.add(key)
    assert selected <= files.keys(), "Missing an expected archive member"
    for shank in shanks:
        assert any(k.startswith(f"recordings/{shank}/") for k in selected)
        assert any(k.startswith(f"postprocessed/{shank}.zarr/") for k in selected)
    return selected


def extract_selected(tar, name, destination, manifest):
    assert destination.is_dir() and not any(destination.iterdir()), destination
    expected = selected_files(manifest)
    seen = set()
    for member in tar.getmembers():
        part = PurePosixPath(member.name)
        assert not part.is_absolute() and ".." not in part.parts and len(part.parts) >= 1
        assert part.parts[0] == name and (member.isfile() or member.isdir()), member.name
        if not member.isfile() or len(part.parts) <= 1:
            continue
        relative = PurePosixPath(*part.parts[1:])
        if str(relative) not in expected:
            continue
        assert str(relative) not in seen, f"Duplicate archive member: {relative}"
        seen.add(str(relative))
        output = destination.joinpath(*relative.parts)
        assert not output.exists() and not output.is_symlink(), output
        output.parent.mkdir(parents=True, exist_ok=True)
        h = hashlib.sha256()
        with tar.extractfile(member) as source, output.open("xb") as target:
            for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
                h.update(block)
                target.write(block)
        record = manifest["files"][str(relative)]
        assert output.stat().st_size == record["size"] == member.size
        assert h.hexdigest() == record["sha256"], f"Archive member checksum mismatch: {relative}"
    assert seen == expected, f"Archive selected file set differs: {expected ^ seen}"
    return {"files": len(seen), "bytes": sum(manifest["files"][k]["size"] for k in seen)}


def stage(user_root, index):
    u, rel, pilot, report_path = source_paths(user_root, index)
    root = u / TEST
    inventory = json.loads((root / "inventory" / (rel.split("/")[-1] + ".json")).read_text())
    report = json.loads(report_path.read_text())
    archive = Path(inventory["archive"])
    assert inventory["session"] == rel and report["verified"] is True
    assert inventory["archive_sha256"] == report["sha256"]
    assert inventory["report"] == str(report_path)
    assert archive == Path(report["archive"]) and archive.stat().st_size == report["size"]
    destination = root / "staged" / rel
    assert not destination.exists() and not destination.is_symlink(), destination
    with tarfile.open(archive, "r:") as tar:
        name = rel.split("/")[-1]
        source_manifest = tar.extractfile(f"{name}/archive_manifest.json")
        assert source_manifest is not None
        manifest_bytes = source_manifest.read()
        manifest = json.loads(manifest_bytes)
        assert manifest["session"] == name and manifest["shanks"] == report["shanks"]
        assert len(selected_files(manifest)) - 2 == inventory["selected_files"] + 4
        destination.mkdir(parents=True)
        extracted = extract_selected(tar, name, destination, manifest)
    (destination / "archive_manifest.json").write_bytes(manifest_bytes)
    metadata = {"session": rel, "archive": str(archive), "archive_report": str(report_path),
                "archive_sha256_from_restore_verified_report": report["sha256"],
                "archive_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
                "extracted": extracted, "source_pilot": str(pilot)}
    (destination / "stage_report.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (destination / "stage_complete").write_text("passed\n")
    print(json.dumps(metadata, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    parser.add_argument("--index", type=int, choices=range(5), required=True)
    args = parser.parse_args()
    stage(args.user_root, args.index)
