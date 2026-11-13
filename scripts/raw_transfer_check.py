#!/usr/bin/env python3
"""Check a cohort of SpikeGLX raw data copied to Arrhenius (standard library only, Python >= 3.8).

1. inventory (source side, e.g. the office computer reading the SMB share, before the transfer):
       python raw_transfer_check.py inventory SOURCE_COHORT_DIR --cohort cohort10 -o cohort10_manifest.json
   Lists every file with its size and validates layout and SpikeGLX metadata. Large .bin files are
   not read: their SHA1 is taken from the .meta file (fileSHA1, written by SpikeGLX at acquisition).
   Files without such a checksum (small files, .cbin, ...) are hashed here.
2. transfer the cohort directory to raw_ecephys/<cohort> and the manifest to any other folder.
3. verify (cluster side, as a Slurm job: scripts/raw_transfer_check.sh):
       python3 raw_transfer_check.py verify cohort10_manifest.json raw_ecephys/cohort10 --workers 8
   Checks every listed file is present with the listed size and SHA1, and that nothing else is.
   A match proves the data equal what SpikeGLX recorded, through every copy in between.

Expected layout below the cohort directory: DATE/SESSION/<probe folder>/<name>.imecN.ap.{bin,meta},
with DATE as YYYYMMDD; arrhenius_batch.py treats each DATE/SESSION folder as one session.
Exit status is 0 only without errors. Warnings flag values that differ from earlier cohorts.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import sys
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

FORMAT = "raw_transfer_manifest/1"
JUNK = re.compile(r"^(\.DS_Store|Thumbs\.db|desktop\.ini|\._.*)$", re.IGNORECASE)
# Values shared by cohorts 06-09 (NP2.0 4-shank, full 384+1 channel save, 30 kHz AP).
EXPECTED_AP = {"typeThis": "imec", "imDatPrb_type": "2013", "imSampRate": "30000", "nSavedChans": "385"}
META_KEYS = ("typeThis", "imDatPrb_type", "imDatPrb_pn", "imDatPrb_sn", "imSampRate", "niSampRate",
             "nSavedChans", "fileTimeSecs", "fileCreateTime", "appVersion")
CHUNK = 16 * 1024 * 1024


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest().upper()


def read_meta(path):
    meta = {}
    for line in Path(path).read_text(encoding="latin-1").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            meta[key.strip()] = value.strip()
    return meta


def walk(root):
    """Relative POSIX paths of all files below root, split into data files and junk files."""
    files, junk = [], []
    for directory, dirs, names in os.walk(root):
        dirs.sort()
        for name in sorted(names):
            rel = (Path(directory) / name).relative_to(root).as_posix()
            (junk if JUNK.match(name) else files).append(rel)
    return files, junk


def session_of(rel):
    parts = rel.split("/")
    return "/".join(parts[:2]) if len(parts) > 2 else None


def inventory(args):
    root = Path(args.source).resolve()
    errors, warnings = [], []
    if not root.is_dir():
        sys.exit(f"Not a directory: {root}")
    if not re.fullmatch(r"cohort\d+", args.cohort):
        sys.exit(f"--cohort must look like cohort10, got {args.cohort!r}")
    files, junk = walk(root)
    if junk:
        warnings.append(f"{len(junk)} system files (.DS_Store etc.) are not listed; exclude them from the transfer")
    entries, sessions = {}, {}
    for rel in files:
        path = root / rel
        entries[rel] = {"size": path.stat().st_size}
        session = session_of(rel)
        if session is None:
            warnings.append(f"File outside any DATE/SESSION folder (will not be sorted): {rel}")
            continue
        date, name = session.split("/")
        if session not in sessions:
            sessions[session] = {"streams": {}}
            if not re.fullmatch(r"20\d{6}", date):
                errors.append(f"Date folder is not YYYYMMDD: {session}")
            elif date not in name or not re.search(r"_g\d+$", name):
                warnings.append(f"Session name does not contain its date folder or end in _gN: {session}")
        if rel.endswith(".bin") and not (root / (rel[:-4] + ".meta")).is_file():
            errors.append(f"Binary without .meta: {rel}")
    for rel in files:
        if not rel.endswith(".meta") or session_of(rel) is None:
            continue
        meta = read_meta(root / rel)
        stream = rel[:-5]
        binary = next((stream + ext for ext in (".bin", ".cbin") if stream + ext in entries), None)
        info = {k: meta[k] for k in META_KEYS if k in meta}
        sessions[session_of(rel)]["streams"][stream.split("/")[-1]] = info
        if binary is None:
            errors.append(f".meta without binary: {rel}")
            continue
        info["binary"] = binary
        if binary.endswith(".bin"):
            expected = meta.get("fileSizeBytes")
            if expected is None or int(expected) != entries[binary]["size"]:
                errors.append(f"Size {entries[binary]['size']} != fileSizeBytes {expected} (truncated copy on the source?): {binary}")
            channels = int(meta.get("nSavedChans", "0"))
            if channels and entries[binary]["size"] % (2 * channels):
                errors.append(f"Size is not a whole number of {channels}-channel int16 samples: {binary}")
            if re.fullmatch(r"[0-9A-Fa-f]{40}", meta.get("fileSHA1", "")):
                entries[binary].update(sha1=meta["fileSHA1"].upper(), sha1_from="meta")
        if binary.endswith(".ap.bin") or binary.endswith(".ap.cbin"):
            for key, value in EXPECTED_AP.items():
                if meta.get(key) != value:
                    warnings.append(f"{key}={meta.get(key)} (earlier cohorts: {value}): {rel}")
    for session, info in sessions.items():
        if not any(s.endswith(".ap") for s in info["streams"]):
            errors.append(f"No AP stream (.ap.bin + .ap.meta): {session}")
    unhashed = [rel for rel, e in entries.items() if "sha1" not in e]
    big = [rel for rel in unhashed if entries[rel]["size"] > 64 * 1024 * 1024]
    if big:
        warnings.append(f"Hashing {len(big)} large files without a SpikeGLX checksum on the source: {big[:5]}")
    for rel in unhashed:
        entries[rel].update(sha1=sha1(root / rel), sha1_from="source")
    manifest = {"format": FORMAT, "cohort": args.cohort, "created": datetime.now(timezone.utc).isoformat(),
                "source": str(root), "host": platform.node(), "files": entries, "sessions": sessions,
                "ignored_system_files": junk, "errors": errors, "warnings": warnings}
    out = Path(args.output or f"{args.cohort}_manifest.json")
    out.write_text(json.dumps(manifest, indent=1))
    total = sum(e["size"] for e in entries.values())
    print(f"{args.cohort}: {len(sessions)} sessions, {len(entries)} files, {total / 1e9:.1f} GB -> {out}")
    for session, info in sorted(sessions.items()):
        ap = next((v for k, v in info["streams"].items() if k.endswith(".ap")), {})
        minutes = float(ap.get("fileTimeSecs", "nan")) / 60
        print(f"  {session}: streams {sorted(info['streams'])}, AP {minutes:.1f} min, probe {ap.get('imDatPrb_pn')}")
    return report(errors, warnings)


def verify(args):
    manifest = json.loads(Path(args.manifest).read_text())
    if manifest.get("format") != FORMAT:
        sys.exit(f"Not a {FORMAT} file: {args.manifest}")
    root = Path(args.dest).resolve()
    errors, warnings = list(manifest["errors"]), []
    if manifest["errors"]:
        warnings.append("The manifest was written with source errors (listed above as errors)")
    if root.name != manifest["cohort"]:
        warnings.append(f"Destination folder {root.name} is not named after the cohort {manifest['cohort']}")
    files, junk = walk(root) if root.is_dir() else ([], [])
    if not root.is_dir():
        errors.append(f"Destination missing: {root}")
    if junk:
        warnings.append(f"{len(junk)} system files at the destination (harmless, can be deleted): {junk[:3]}")
    expected = manifest["files"]
    for rel in sorted(set(files) - set(expected)):
        (errors if rel.endswith((".bin", ".cbin", ".meta")) else warnings).append(f"Not in manifest: {rel}")
    status = {}
    todo = []
    for rel, entry in expected.items():
        path = root / rel
        if not path.is_file():
            status[rel] = "missing"
        elif path.stat().st_size != entry["size"]:
            status[rel] = f"size {path.stat().st_size} != {entry['size']}"
        else:
            todo.append(rel)
    started, done_bytes = time.time(), 0
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(sha1, root / rel): rel for rel in todo}
        for future in as_completed(futures):
            rel = futures[future]
            got, want = future.result(), expected[rel]["sha1"]
            status[rel] = "ok" if got == want else f"sha1 {got} != {want} ({expected[rel]['sha1_from']})"
            done_bytes += expected[rel]["size"]
            if expected[rel]["size"] > 1e9:
                rate = done_bytes / 1e6 / max(time.time() - started, 1e-3)
                print(f"  {status[rel]:>4}  {rel}  ({done_bytes / 1e9:.0f} GB done, {rate:.0f} MB/s)", flush=True)
    errors += [f"{state}: {rel}" for rel, state in sorted(status.items()) if state != "ok"]
    others = {}
    for cohort in root.parent.glob("cohort*"):
        if cohort != root and cohort.is_dir():
            for session in cohort.glob("*/*"):
                others.setdefault(session.name, []).append(session.relative_to(root.parent).as_posix())
    for session in manifest["sessions"]:
        name = session.split("/")[1]
        if name in others:
            warnings.append(f"Session name also exists in {others[name]}: {session}")
    rows = []
    for session in sorted(manifest["sessions"]):
        mine = [rel for rel in expected if rel.startswith(session + "/")]
        bad = [rel for rel in mine if status[rel] != "ok"]
        rows.append({"session": session, "files": len(mine), "bytes": sum(expected[r]["size"] for r in mine),
                     "status": "OK" if not bad else "FAIL", "problems": [f"{status[r]}: {r}" for r in bad]})
    out = Path(args.report or Path(args.manifest).with_name(
        f"{manifest['cohort']}_verify_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"))
    out.write_text(json.dumps({"manifest": str(Path(args.manifest).resolve()), "dest": str(root),
                               "host": platform.node(), "finished": datetime.now(timezone.utc).isoformat(),
                               "sessions": rows, "errors": errors, "warnings": warnings}, indent=1))
    for row in rows:
        print(f"{row['status']:>4}  {row['session']}  {row['files']} files  {row['bytes'] / 1e9:.1f} GB")
    print(f"Report: {out}")
    return report(errors, warnings)


def report(errors, warnings):
    for w in warnings:
        print("WARNING:", w)
    for e in errors:
        print("ERROR:", e)
    print("RESULT:", "FAIL" if errors else "PASS", f"({len(errors)} errors, {len(warnings)} warnings)")
    return 1 if errors else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("inventory", help="Source side: write the manifest")
    p.add_argument("source", help="Cohort directory on the source (contains DATE/SESSION/...)")
    p.add_argument("--cohort", required=True, help="Cohort folder name on the cluster, e.g. cohort10")
    p.add_argument("-o", "--output", help="Manifest path (default: <cohort>_manifest.json)")
    p.set_defaults(func=inventory)
    p = sub.add_parser("verify", help="Destination side: check the copy against the manifest")
    p.add_argument("manifest")
    p.add_argument("dest", help="Copied cohort directory, e.g. raw_ecephys/cohort10")
    p.add_argument("--workers", type=int, default=4, help="Files hashed in parallel")
    p.add_argument("--report", help="Report path (default: next to the manifest)")
    p.set_defaults(func=verify)
    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
