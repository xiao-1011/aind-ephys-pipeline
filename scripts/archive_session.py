#!/usr/bin/env python3
"""Build and restore-test a portable session archive. Never delete source outputs.

Run inside the pipeline-base image (SpikeInterface, Zarr, pynwb, hdmf-zarr).
Plain tar is intentional: one inode, no recompression of already-compressed Zarr.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import tarfile
import tempfile
from datetime import datetime, timezone


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w") as f:
        json.dump(value, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    tmp.replace(path)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(8 * 1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def recording_paths_inside(recording, root):
    from spikeinterface.core.core_tools import _get_paths_list

    for value in _get_paths_list(recording.to_dict(recursive=True)):
        p = Path(value).resolve()
        require(p.is_relative_to(root.resolve()), f"Recording depends on external path: {p}")
        require(p.exists(), f"Missing recording dependency: {p}")


def summarize(root):
    import numpy as np
    import spikeinterface as si

    rows = {}
    for folder in sorted((root / "curated").iterdir()):
        if not folder.is_dir():
            continue
        sorting = si.load(folder)
        labels = sorting.get_property("unitrefine_label")
        qc = sorting.get_property("default_qc")
        require(qc is not None, f"Missing default QC: {folder}")
        sua = labels == "sua" if labels is not None else np.zeros(len(qc), dtype=bool)
        rows[folder.name] = {
            "units": int(sorting.get_num_units()),
            "qc_pass": int(np.asarray(qc, dtype=bool).sum()),
            "sua": int(sua.sum()),
            "sua_qc_pass": int((sua & np.asarray(qc, dtype=bool)).sum()),
        }
        require((root / "postprocessed" / f"{folder.name}.zarr").is_dir(), f"Missing analyzer: {folder.name}")
        require((root / "preprocessed" / f"{folder.name}.json").is_file(), f"Missing recording: {folder.name}")
    require(rows, "No curated sortings")
    return rows


def trace_check(results):
    with (results / "nextflow/trace.txt").open() as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    require(rows and all(r["status"] in ("COMPLETED", "CACHED") for r in rows), "Incomplete/failed Nextflow tasks")
    names = {r["name"].split("(")[-1].rstrip(")") for r in rows}
    require({"nwb-units", "qc-collector", "result-collector", "spikesort-kilosort4"} <= names, "Missing final pipeline steps")
    require((results / "quality_control.json").is_file(), "Missing final QC JSON")


def copy_binary_file(src, dst):
    # Hardlink only immutable trace bytes while staging; copy all metadata because
    # it will be rewritten. tar stores the actual bytes, not links to source paths.
    if Path(src).suffix == ".raw":
        try:
            os.link(src, dst)
            return dst
        except OSError:
            pass
    return shutil.copy2(src, dst)


def sample_hashes(recording):
    samples = []
    for segment in range(recording.get_num_segments()):
        n = recording.get_num_samples(segment)
        for fraction in (0.1, 0.5, 0.9):
            start = int(n * fraction)
            end = min(start + 1000, n)
            data = recording.get_traces(segment_index=segment, start_frame=start, end_frame=end)
            samples.append({"segment": segment, "start": start, "end": end,
                            "sha256": hashlib.sha256(data.tobytes()).hexdigest()})
    return samples


def prepare(args, parent):
    import numpy as np
    import spikeinterface as si
    from spikeinterface.core.core_tools import check_json
    import zarr

    source, raw, work = args.results.resolve(), args.raw.resolve(), args.work.resolve()
    require(source.is_dir() and raw.is_dir() and work.is_dir(), "Missing source/raw/work directory")
    trace_check(source)
    require(not any(p.is_symlink() for p in source.rglob("*")), "Results contain symlinks; refusing implicit external dependencies")
    bundle = parent / raw.name
    shutil.copytree(source, bundle)
    summary = summarize(source)
    samples = {}
    binary_root = bundle / "recordings"
    binary_root.mkdir()
    for name in summary:
        original = si.load(source / "preprocessed" / f"{name}.json", base_folder=raw)
        require(type(original).__name__ == "BinaryFolderRecording", f"Unsupported extractor: {original}")
        binary_source = Path(original._kwargs["folder_path"]).resolve()
        require(binary_source.is_relative_to(work), f"Binary outside this session's work directory: {binary_source}")
        target = binary_root / name
        shutil.copytree(binary_source, target, copy_function=copy_binary_file)
        portable = si.load(target)
        require(np.array_equal(original.channel_ids, portable.channel_ids), "Channel IDs changed")
        samples[name] = sample_hashes(original)
        require(samples[name] == sample_hashes(portable), f"Copied recording differs: {name}")
        portable.dump_to_json(bundle / "preprocessed" / f"{name}.json", relative_to=bundle / "preprocessed")
        analyzer_path = bundle / "postprocessed" / f"{name}.zarr"
        group = zarr.open(str(analyzer_path), mode="a")
        group["recording"][0] = check_json(portable.to_dict(relative_to=analyzer_path, recursive=True))
        zarr.consolidate_metadata(group.store)
    provenance = bundle / "archive_provenance"
    provenance.mkdir()
    if args.provenance:
        for name in ("active_params.json", "default_params_schema.json", "capsule_versions.env", "pipeline_version.txt", "nextflow_arrhenius.config", "main_multi_backend.nf"):
            src = args.provenance / "pipeline" / name
            if src.exists():
                shutil.copy2(src, provenance / name)
        for name in ("source_commit.txt", "source_diff.patch", "si4830_recovery.json",
                     "si4830_image.provenance.json", "si4830_image.sha256",
                     "si4830_verification.json"):
            src = args.provenance / name
            if src.exists():
                shutil.copy2(src, provenance / name)
    (bundle / "RESTORE.md").write_text(
        "# Restoring this archive\n\nExtract with `tar -xf SESSION.tar`. Corrected traces are in `recordings/`.\n"
        "Load `preprocessed/NAME.json` with SpikeInterface and `base_folder=ROOT/preprocessed`.\n"
        "Load analyzers with `si.load_sorting_analyzer(ROOT/postprocessed/NAME.zarr)`.\n"
        "NWB is a Zarr store: use `hdmf_zarr.NWBZarrIO`. Raw data are not included.\n"
        "Historical logs/provenance may mention old paths; operational recording references are portable.\n"
    )
    files = {}
    for p in sorted(bundle.rglob("*")):
        require(not p.is_symlink(), f"Symlink in archive staging: {p}")
        if p.is_file():
            files[str(p.relative_to(bundle))] = {"size": p.stat().st_size, "sha256": digest(p)}
    manifest = {"format": 1, "created_at": datetime.now(timezone.utc).isoformat(),
                "session": raw.name, "source_results": str(source), "raw": str(raw),
                "source_work": str(work), "shanks": summary, "samples": samples, "files": files}
    atomic_json(bundle / "archive_manifest.json", manifest)
    print(f"Prepared {raw.name}: {len(files)} files, {sum(v['size'] for v in files.values()) / 1e9:.2f} GB", flush=True)
    return bundle


def verify_bundle(root, manifest):
    import numpy as np
    import spikeinterface as si
    import spikeinterface.preprocessing as spre
    from hdmf_zarr import NWBZarrIO

    require(summarize(root) == manifest["shanks"], "Restored curated counts differ")
    for name in manifest["shanks"]:
        rec = si.load(root / "preprocessed" / f"{name}.json", base_folder=root / "preprocessed")
        recording_paths_inside(rec, root)
        require(sample_hashes(rec) == manifest["samples"][name], f"Restored trace samples differ: {name}")
        analyzer = si.load_sorting_analyzer(root / "postprocessed" / f"{name}.zarr", load_extensions=True, read_only=True)
        require(analyzer.recording is not None, f"Analyzer recording failed to load: {name}")
        recording_paths_inside(analyzer.recording, root)
        require(sample_hashes(analyzer.recording) == manifest["samples"][name], f"Analyzer trace samples differ: {name}")
        si.load(root / "spikesorted" / name).to_spike_vector()
        motion_info = spre.load_motion_info(root / "preprocessed/motion" / name)
        require(motion_info["motion"] is not None, f"Missing DREDge motion: {name}")
        require(all(np.isfinite(d).all() for d in motion_info["motion"].displacement), f"Nonfinite motion: {name}")
    units = 0
    nwbs = list((root / "nwb").glob("*.nwb"))
    require(nwbs, "Missing NWB store")
    for path in nwbs:
        with NWBZarrIO(str(path), mode="r", load_namespaces=True) as io:
            nwb = io.read()
            require(nwb.units is not None, f"Missing NWB units: {path}")
            units += len(nwb.units)
            if len(nwb.units):
                nwb.units["spike_times"][0]
    require(units == sum(v["units"] for v in manifest["shanks"].values()), "NWB unit count differs from curated sortings")
    print(f"Restore test passed: {len(manifest['shanks'])} shanks, {units} NWB units, recordings/analyzers independent of work/raw paths", flush=True)


def restore_verify(archive, parent):
    restore = parent / "restored"
    restore.mkdir()
    with tarfile.open(archive, "r:") as tar:
        members = tar.getmembers()
        roots = set()
        seen = set()
        for m in members:
            p = PurePosixPath(m.name)
            require(not p.is_absolute() and ".." not in p.parts and p.parts, f"Unsafe archive member: {m.name}")
            require(m.isdir() or m.isfile(), f"Unsupported archive member: {m.name}")
            require(m.name not in seen, f"Duplicate archive member: {m.name}")
            seen.add(m.name)
            roots.add(p.parts[0])
        require(len(roots) == 1, "Archive must contain one session root")
        name = roots.pop()
        manifest = json.load(tar.extractfile(f"{name}/archive_manifest.json"))
        found = set()
        for m in members:
            dest = restore / m.name
            if m.isdir():
                dest.mkdir(parents=True, exist_ok=True)
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            h = hashlib.sha256()
            with tar.extractfile(m) as src, dest.open("wb") as out:
                for block in iter(lambda: src.read(8 * 1024 * 1024), b""):
                    h.update(block)
                    out.write(block)
            rel = str(PurePosixPath(m.name).relative_to(name))
            if rel == "archive_manifest.json":
                continue
            expected = manifest["files"].get(rel)
            require(expected is not None and expected["size"] == m.size and expected["sha256"] == h.hexdigest(), f"Archive checksum mismatch: {rel}")
            found.add(rel)
        require(found == set(manifest["files"]), "Archive file inventory differs")
    verify_bundle(restore / name, manifest)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("pack", "verify"))
    parser.add_argument("--results", type=Path)
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--staging-root", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--provenance", type=Path)
    args = parser.parse_args()
    args.staging_root.mkdir(parents=True, exist_ok=True)
    parent = Path(tempfile.mkdtemp(prefix="archive-test-", dir=args.staging_root))
    print(f"Archive staging: {parent}", flush=True)
    try:
        if args.mode == "pack":
            require(args.results and args.raw and args.work, "pack requires --results, --raw, --work")
            require(not args.archive.exists(), f"Archive already exists: {args.archive}")
            partial = args.archive.with_name(args.archive.name + ".partial")
            require(not partial.exists(), f"Partial archive exists; inspect before retry: {partial}")
            args.archive.parent.mkdir(parents=True, exist_ok=True)
            bundle = prepare(args, parent)
            with tarfile.open(partial, "w:", dereference=True) as tar:
                tar.add(bundle, arcname=bundle.name)
            with partial.open("rb") as f:
                os.fsync(f.fileno())
            manifest = restore_verify(partial, parent)
            checksum = digest(partial)
            require(not args.archive.exists(), "Archive appeared during verification")
            partial.rename(args.archive)
            directory_fd = os.open(args.archive.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        else:
            manifest = restore_verify(args.archive, parent)
            checksum = digest(args.archive)
        report = {"verified": True, "archive": str(args.archive.resolve()), "sha256": checksum,
                  "size": args.archive.stat().st_size, "session": manifest["session"],
                  "source_results": manifest["source_results"], "source_work": manifest["source_work"],
                  "raw": manifest["raw"], "shanks": manifest["shanks"]}
        atomic_json(args.report, report)
        # Only our uniquely-created staging directory; source outputs are never removed here.
        shutil.rmtree(parent)
        print(json.dumps(report), flush=True)
    except Exception:
        print(f"FAILED: sources untouched; staging retained at {parent}", flush=True)
        raise


if __name__ == "__main__":
    main()
