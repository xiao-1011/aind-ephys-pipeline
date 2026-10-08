#!/usr/bin/env python3
"""Detached sequential Slurm runner: sort, restore-test an archive, then clean.

All raw data and pre-existing result/work trees are preserved. Only directories
created under this batch's own outputs/ and work/ roots may be deleted.
"""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import traceback

from archive_session import atomic_json, digest, require, trace_check


def now():
    return datetime.now(timezone.utc).isoformat()


def update(batch, manifest, row, status, **extra):
    row.update(status=status, updated_at=now(), **extra)
    manifest["updated_at"] = now()
    atomic_json(batch / "manifest.json", manifest)
    with (batch / "progress.jsonl").open("a") as f:
        f.write(json.dumps({"time": now(), "session": row["relative"], "status": status, **extra}) + "\n")
    with (batch / "summary.tsv").open("w") as f:
        f.write("session\tstatus\tunits\tqc_pass\tsua\tsua_qc_pass\tarchive\n")
        for entry in manifest["sessions"]:
            totals = entry.get("totals", {})
            f.write("\t".join([entry["relative"], entry["status"],
                               *[str(totals.get(k, "")) for k in ("units", "qc_pass", "sua", "sua_qc_pass")],
                               entry["archive"]]) + "\n")
    print(f"{now()} {row['relative']}: {status} {extra}", flush=True)


def totals(report):
    return {key: sum(v[key] for v in report["shanks"].values())
            for key in ("units", "qc_pass", "sua", "sua_qc_pass")}


def archive_params_hash(archive):
    with tarfile.open(archive, "r:") as tar:
        member, = [m for m in tar.getmembers() if m.name.endswith("/archive_provenance/active_params.json")]
        import hashlib
        return hashlib.sha256(tar.extractfile(member).read()).hexdigest()


def validate_report(report, row, params_hash):
    archive = Path(row["archive"])
    require(report.get("verified") is True, "Archive has no successful restore verification")
    require(report["archive"] == str(archive.resolve()), "Archive report path mismatch")
    require(report["raw"] == row["raw"], "Archive raw session mismatch")
    require(report["session"] == Path(row["raw"]).name, "Archive session mismatch")
    require(archive.is_file() and archive.stat().st_size == report["size"], "Archive absent or size changed")
    require(digest(archive) == report["sha256"], "Archive checksum changed")
    require(archive_params_hash(archive) == params_hash, "Archive used different parameters")


def remove_owned(target, root, relative):
    # Cleanup is deliberately constrained to three-component cohort/date/session
    # directories under a fresh, batch-owned root. Never touch raw or old outputs.
    root = root.resolve()
    relative = Path(relative)
    require(len(relative.parts) == 3 and ".." not in relative.parts and not relative.is_absolute(), "Unsafe session name")
    expected = root / relative
    require(not target.is_symlink(), f"Unsafe cleanup symlink: {target}")
    target = target.parent.resolve() / target.name
    require(target == expected, f"Unsafe cleanup target: {target}")
    require(target.resolve().is_relative_to(root), f"Cleanup escapes owned root: {target}")
    if target.exists():
        shutil.rmtree(target)
    parent = target.parent
    while parent != root:
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent


def start(args):
    user_root = args.user_root.resolve()
    repo = Path(__file__).resolve().parents[1]
    raw_root = user_root / "raw_ecephys"
    archive_root = (args.archive_root or user_root / "session_archives").resolve()
    require(archive_root.is_relative_to(user_root / "session_archives"),
            "Archive root must be inside the session_archives directory")
    pilot = json.loads(args.pilot_report.read_text()) if args.pilot_report else None
    sessions = []
    for raw in sorted(raw_root.glob("*/*/*")):
        if not raw.is_dir():
            continue
        require(not raw.is_symlink(), f"Symlink session must be selected explicitly: {raw}")
        binaries = list(raw.rglob("*.ap.bin")) + list(raw.rglob("*.ap.cbin"))
        require(binaries and all(p.stat().st_size > 0 for p in binaries), f"Missing AP data: {raw}")
        rel = str(raw.relative_to(raw_root))
        sessions.append({"relative": rel, "raw": str(raw), "archive": str(archive_root / (rel + ".tar")), "status": "pending"})
    require(sessions, "No raw sessions discovered")
    batch = user_root / "batch_runs" / datetime.now().strftime("%Y%m%d_%H%M%S")
    batch.mkdir(parents=True, exist_ok=False)
    snapshot = batch / "snapshot"
    shutil.copytree(repo / "pipeline", snapshot / "pipeline")
    shutil.copytree(repo / "scripts", snapshot / "scripts", ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("outputs", "work", "logs", "reports", "archive_staging"):
        (batch / name).mkdir()
    params_hash = digest(snapshot / "pipeline/active_params.json")
    manifest = {"batch": str(batch), "created_at": now(), "user_root": str(user_root),
                "params_sha256": params_hash, "sessions": sessions, "status": "prepared"}
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    (snapshot / "source_commit.txt").write_text(commit + "\n")
    diff = subprocess.check_output(["git", "diff", "HEAD"], cwd=repo)
    (snapshot / "source_diff.patch").write_bytes(diff)
    for row in sessions:
        archive = Path(row["archive"])
        if not archive.exists():
            require(not archive.with_name(archive.name + ".partial").exists(), f"Inspect existing partial archive: {archive}")
            continue
        require(pilot and pilot["raw"] == row["raw"], f"Existing archive has no supplied verification report: {archive}")
        validate_report(pilot, row, params_hash)
        atomic_json(batch / "reports" / (Path(row["relative"]).name + ".json"), pilot)
        update(batch, manifest, row, "archived_pilot_sources_preserved", totals=totals(pilot))
    manifest["status"] = "submitted"
    atomic_json(batch / "manifest.json", manifest)
    (batch / "sessions.txt").write_text("\n".join(row["relative"] for row in sessions) + "\n")
    job = subprocess.check_output(
        ["sbatch", "--parsable", "--output", str(batch / "logs/batch-%j.out"),
         str(snapshot / "scripts/arrhenius_batch_controller.sh"), str(batch)], text=True
    ).strip().split(";")[0]
    # Do not rewrite manifest here: the controller may already be updating it.
    # The running controller records its Slurm ID itself.
    atomic_json(user_root / "batch_runs/latest.json", {"batch": str(batch), "controller_job": job})
    print(f"DETACHED BATCH SUBMITTED: job {job}, {len(sessions)} sessions; progress: {batch}/summary.tsv", flush=True)


def run(args):
    batch = args.batch.resolve()
    manifest = json.loads((batch / "manifest.json").read_text())
    user_root = Path(manifest["user_root"])
    require(batch.is_relative_to(user_root / "batch_runs"), "Batch directory outside authorized root")
    snapshot = batch / "snapshot"
    require(digest(snapshot / "pipeline/active_params.json") == manifest["params_sha256"], "Frozen parameters changed")
    lock_path = user_root / "session_archives/.batch.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        manifest["controller_job"] = os.environ.get("SLURM_JOB_ID", "manual")
        manifest["status"] = "running"
        atomic_json(batch / "manifest.json", manifest)
        env = dict(os.environ, PIPELINE_PATH=str(snapshot), NXF_SESSION_WORK_ROOT=str(batch / "work"))
        image = user_root / "apptainer_cache/ghcr.io-allenneuraldynamics-aind-ephys-pipeline-base-1.4.0.img"
        row = None
        try:
            for row in manifest["sessions"]:
                if row["status"] in ("complete", "archived_pilot_sources_preserved"):
                    continue
                rel = Path(row["relative"])
                results, work = batch / "outputs" / rel, batch / "work" / rel
                report_path = batch / "reports" / (rel.name + ".json")
                archive = Path(row["archive"])
                if not archive.exists():
                    pipeline_complete = False
                    if (results / "nextflow/trace.txt").exists():
                        try:
                            trace_check(results)
                            pipeline_complete = True
                        except RuntimeError:
                            pass
                    if not pipeline_complete:
                        # First attempt is fresh; a restarted batch can resume its
                        # own incomplete session, never someone else's work tree.
                        env["ARRHENIUS_FRESH_RUN"] = "0" if work.exists() else "1"
                        update(batch, manifest, row, "running")
                        log_pattern = str(batch / "logs" / (rel.name + "-%j.out"))
                        output = subprocess.check_output(
                            ["sbatch", "--wait", "--parsable", "-o", log_pattern,
                             str(snapshot / "pipeline/arrhenius_submit.sh"), row["raw"], str(results)],
                            env=env, text=True,
                        )
                        row["pipeline_job"] = output.strip().split(";")[0]
                    trace_check(results)
                    update(batch, manifest, row, "archiving")
                    subprocess.run(
                        ["apptainer", "exec", "-B", str(user_root), str(image), "python", "-u",
                         str(snapshot / "scripts/archive_session.py"), "pack", "--results", str(results),
                         "--raw", row["raw"], "--work", str(work), "--archive", str(archive),
                         "--staging-root", str(batch / "archive_staging"), "--report", str(report_path),
                         "--provenance", str(snapshot)], check=True,
                    )
                elif not report_path.exists():
                    # Recover interruption between publishing the archive and
                    # committing its verification report; sources stay intact.
                    subprocess.run(
                        ["apptainer", "exec", "-B", str(user_root), str(image), "python", "-u",
                         str(snapshot / "scripts/archive_session.py"), "verify", "--archive", str(archive),
                         "--staging-root", str(batch / "archive_staging"), "--report", str(report_path)], check=True,
                    )
                report = json.loads(report_path.read_text())
                validate_report(report, row, manifest["params_sha256"])
                require(report["source_results"] == str(results) and report["source_work"] == str(work), "Cleanup provenance mismatch")
                update(batch, manifest, row, "verified", totals=totals(report), sha256=report["sha256"])
                remove_owned(results, batch / "outputs", row["relative"])
                remove_owned(work, batch / "work", row["relative"])
                update(batch, manifest, row, "complete", totals=totals(report))
            manifest["status"] = "complete"
            atomic_json(batch / "manifest.json", manifest)
            print("BATCH COMPLETE: all sessions archived; raw data and pre-existing runs preserved", flush=True)
        except BaseException as exc:
            if row:
                update(batch, manifest, row, "failed", error=str(exc))
            manifest["status"] = "failed"
            atomic_json(batch / "manifest.json", manifest)
            traceback.print_exc()
            print("BATCH STOPPED: failing session retained; inspect logs before restarting", flush=True)
            raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    start_parser = sub.add_parser("start")
    start_parser.add_argument("--user-root", type=Path, required=True)
    start_parser.add_argument("--archive-root", type=Path, help="Isolated archive root under user-root/session_archives")
    start_parser.add_argument("--pilot-report", type=Path)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("batch", type=Path)
    args = parser.parse_args()
    (start if args.mode == "start" else run)(args)
