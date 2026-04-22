#!/usr/bin/env python3
"""
Pipeline status + failure analysis for multishankv2.

For each session/probe/shank, checks which outputs exist on disk and,
for any missing output, looks up all past attempts in the Nextflow trace
files to report status, exit code, duration, and a plain-English verdict.

Usage:
    python check_status.py [--results RESULTS_DIR] [--logs LOGS_DIR]

Defaults point to the multishankv2-batch2 output on Dardel.
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DEFAULT_RESULTS = "/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/multishankv2-batch2/results"
DEFAULT_LOGS    = "/cfs/klemming/projects/supr/dmclab/ephys-pipeline-output/multishankv2-batch2/logs"

# Sorter outputs to check (dir name → short label)
SORTERS = {
    "sorter_kilosort4":      "KS4-sort",
    "sorter_spykingcircus2": "SC2-sort",
    "sorter_tridesclous2":   "TDC2-sort",
}

# Analyzer outputs to check (dir name → short label)
ANALYZERS = {
    "analyzer_kilosort4":      "KS4-ana",
    "analyzer_spykingcircus2": "SC2-ana",
    "analyzer_tridesclous2":   "TDC2-ana",
}

# Curation outputs to check (file name → short label)
CURATIONS = {
    "advanced_curation_kilosort4.json":      "KS4-cur",
    "advanced_curation_spykingcircus2.json": "SC2-cur",
    "advanced_curation_tridesclous2.json":   "TDC2-cur",
}

# Disk output → (trace process name, tag builder fn)
# Tag builder receives (session, probe, shank) and returns the string
# that appears inside the parentheses in the trace name column.
OUTPUT_TO_TRACE = {
    "sorter_kilosort4":      ("SORT_KS4_BATCH", lambda s, p, sh: f"{s}/{p}"),
    "sorter_spykingcircus2": ("SORT_SC2",        lambda s, p, sh: f"{s}/{p}/{sh}"),
    "sorter_tridesclous2":   ("SORT_TDC2",       lambda s, p, sh: f"{s}/{p}/{sh}"),
    "analyzer_kilosort4":    ("ANALYZE_KS4",     lambda s, p, sh: f"{s}/{p}/{sh}/sorter_kilosort4"),
    "analyzer_spykingcircus2": ("ANALYZE_SC2",   lambda s, p, sh: f"{s}/{p}/{sh}/sorter_spykingcircus2"),
    "analyzer_tridesclous2": ("ANALYZE_TDC2",    lambda s, p, sh: f"{s}/{p}/{sh}/sorter_tridesclous2"),
    "advanced_curation_kilosort4.json":      ("ADVANCED_CURATE", lambda s, p, sh: f"{s}/{p}/{sh}/analyzer_kilosort4"),
    "advanced_curation_spykingcircus2.json": ("ADVANCED_CURATE", lambda s, p, sh: f"{s}/{p}/{sh}/analyzer_spykingcircus2"),
    "advanced_curation_tridesclous2.json":   ("ADVANCED_CURATE", lambda s, p, sh: f"{s}/{p}/{sh}/analyzer_tridesclous2"),
}

TIMEOUT_EXITS = {"140", "143", "137"}


# ---------------------------------------------------------------------------
# Trace parsing
# ---------------------------------------------------------------------------

def parse_traces(logs_dir: Path) -> dict:
    """Parse all *_trace.txt files and return dict keyed by full task name."""
    # key: "PROCESS_NAME (tag)" → list of attempt dicts (sorted chronologically)
    attempts = defaultdict(list)

    trace_files = sorted(logs_dir.glob("*_trace.txt"),
                         key=lambda p: int(re.search(r"(\d+)_trace", p.name).group(1)))

    for tf in trace_files:
        job_id = re.search(r"(\d+)_trace", tf.name).group(1)
        try:
            with open(tf, newline="") as fh:
                reader = csv.DictReader(fh, delimiter="\t")
                for row in reader:
                    name   = row.get("name", "").strip()
                    status = row.get("status", "").strip()
                    if not name or status in ("CACHED",):
                        continue
                    attempts[name].append({
                        "job_id":    job_id,
                        "status":    status,
                        "exit":      row.get("exit", "-").strip(),
                        "duration":  row.get("duration", "-").strip(),
                        "realtime":  row.get("realtime", "-").strip(),
                        "peak_rss":  row.get("peak_rss", "-").strip(),
                    })
        except Exception as e:
            print(f"  [warn] could not parse {tf.name}: {e}", file=sys.stderr)

    return attempts


def verdict(attempts: list) -> str:
    if not attempts:
        return "never submitted — upstream dependency missing?"
    last = attempts[-1]
    status = last["status"]
    exit_code = last["exit"]
    if status == "COMPLETED":
        return "COMPLETED (publishDir lag?)"
    if status == "ABORTED":
        return "ABORTED (orchestrator killed)"
    if exit_code in TIMEOUT_EXITS:
        return f"TIMEOUT (exit {exit_code})"
    if exit_code not in ("-", ""):
        dur = last["duration"]
        try:
            # rough duration check: < 5 min means early crash
            if "h" not in dur and int(dur.replace("m","").replace("s","").split()[0]) < 5:
                return f"CRASHED EARLY (exit {exit_code})"
        except Exception:
            pass
        return f"CRASHED (exit {exit_code})"
    return f"FAILED (exit={exit_code})"


# ---------------------------------------------------------------------------
# Disk scanning
# ---------------------------------------------------------------------------

def scan_results(results_dir: Path):
    """
    Returns a dict: {(session, probe): {shank: set_of_present_outputs}}
    """
    data = {}
    for session_dir in sorted(results_dir.iterdir()):
        if not session_dir.is_dir() or session_dir.name == "nextflow":
            continue
        session = session_dir.name
        for probe_dir in sorted(session_dir.iterdir()):
            if not probe_dir.is_dir():
                continue
            probe = probe_dir.name
            shanks = {}
            for shank_dir in sorted(probe_dir.glob("shank*")):
                if not shank_dir.is_dir():
                    continue
                shank = shank_dir.name
                present = set()
                for name in list(SORTERS) + list(ANALYZERS):
                    if (shank_dir / name).is_dir():
                        present.add(name)
                for name in CURATIONS:
                    if (shank_dir / name).is_file():
                        present.add(name)
                shanks[shank] = present
            if shanks:
                data[(session, probe)] = shanks
    return data


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def cell(count, total):
    if total == 0:
        return "  -   "
    if count == total:
        return f"✓ {count}/{total}"
    if count == 0:
        return f"✗ {count}/{total}"
    return f"~ {count}/{total}"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="multishankv2 pipeline status checker")
    parser.add_argument("--results", default=DEFAULT_RESULTS, help="Path to results/ directory")
    parser.add_argument("--logs",    default=DEFAULT_LOGS,    help="Path to logs/ directory")
    args = parser.parse_args()

    results_dir = Path(args.results)
    logs_dir    = Path(args.logs)

    if not results_dir.exists():
        sys.exit(f"ERROR: results dir not found: {results_dir}")

    print("Scanning results...", file=sys.stderr)
    disk = scan_results(results_dir)

    print("Parsing trace files...", file=sys.stderr)
    traces = parse_traces(logs_dir) if logs_dir.exists() else {}
    if not traces:
        print("  [warn] no trace files found — failure detail will be unavailable", file=sys.stderr)

    all_outputs = list(SORTERS) + list(ANALYZERS) + list(CURATIONS)
    labels      = list(SORTERS.values()) + list(ANALYZERS.values()) + list(CURATIONS.values())

    # ── Section A: Summary table ─────────────────────────────────────────
    col_w = 13
    label_w = 50
    sep = " | "

    header = f"{'Session/Probe':<{label_w}}" + sep + sep.join(f"{l:^{col_w}}" for l in labels)
    print()
    print("=" * len(header))
    print("SUMMARY TABLE")
    print("=" * len(header))
    print(header)
    print("-" * len(header))

    missing_items = []  # collect for Section B

    for (session, probe), shanks in disk.items():
        n = len(shanks)
        counts = {out: 0 for out in all_outputs}
        for shank, present in shanks.items():
            for out in all_outputs:
                if out in present:
                    counts[out] += 1

        cells = sep.join(f"{cell(counts[out], n):^{col_w}}" for out in all_outputs)
        label = f"{session}/{probe}"
        if len(label) > label_w:
            label = "..." + label[-(label_w - 3):]
        print(f"{label:<{label_w}}{sep}{cells}")

        # collect missing
        for shank, present in sorted(shanks.items()):
            for out in all_outputs:
                if out not in present:
                    missing_items.append((session, probe, shank, out))

    print()

    # ── Section B: Failure detail ────────────────────────────────────────
    if not missing_items:
        print("All outputs present — pipeline complete.")
        return

    print("=" * 80)
    print("FAILURE DETAIL  (missing outputs only)")
    print("=" * 80)

    for session, probe, shank, out in missing_items:
        process_name, tag_fn = OUTPUT_TO_TRACE[out]
        tag = tag_fn(session, probe, shank)
        full_name = f"{process_name} ({tag})"

        task_attempts = traces.get(full_name, [])
        v = verdict(task_attempts)

        print(f"\nMISSING: {session} / {probe} / {shank} / {out}")
        print(f"  Process:  {process_name}")
        print(f"  Attempts: {len(task_attempts)}")
        for i, a in enumerate(task_attempts, 1):
            print(f"  [{i}] job {a['job_id']:>10}  {a['status']:<10}  exit={a['exit']:<5}  "
                  f"duration={a['duration']:<12}  realtime={a['realtime']:<12}  peak_rss={a['peak_rss']}")
        print(f"  → {v}")

    print()


if __name__ == "__main__":
    main()
