#!/usr/bin/env python3
"""Build-time backport of upstream SI PR #4830 onto the exact 0.105.0 source."""
import argparse
import hashlib
from importlib import metadata
import json
from pathlib import Path
import py_compile
import subprocess

UPSTREAM_COMMIT = "2750986478b23a5a4dac721dc550358ebe098813"
ORIGINAL_SHA256 = "8754a660c658aae325e9a30bccc9946eaa59391b2dbe6e54ef2c1154e197f3ef"
PATCHED_SHA256 = "939af57e6d82cabc3ded3ecd4b14ec559ded391411a90124f081b305d5438cb9"
SOURCE = "spikeinterface/curation/train_manual_curation.py"


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def apply(patch, provenance):
    distribution = metadata.distribution("spikeinterface")
    if distribution.version != "0.105.0":
        raise RuntimeError(f"Expected SpikeInterface 0.105.0, found {distribution.version}")
    source = Path(distribution.locate_file(SOURCE)).resolve()
    if sha256(source) != ORIGINAL_SHA256:
        raise RuntimeError(f"Unexpected source (or already patched): {source}")
    packages = sorted((d.metadata["Name"], d.version) for d in metadata.distributions())
    command = ["git", "apply", "--whitespace=error", "-p2", str(patch.resolve())]
    subprocess.run(command[:2] + ["--check"] + command[2:], cwd=source.parents[2], check=True)
    subprocess.run(command, cwd=source.parents[2], check=True)
    if sha256(source) != PATCHED_SHA256:
        raise RuntimeError("Patched source does not exactly match upstream #4830")
    py_compile.compile(str(source), doraise=True,
                       invalidation_mode=py_compile.PycInvalidationMode.CHECKED_HASH)
    report = json.loads(provenance.read_text())
    report.update(upstream_commit=UPSTREAM_COMMIT,
                  upstream_pr="https://github.com/SpikeInterface/spikeinterface/pull/4830",
                  spikeinterface_version=distribution.version, source_file=str(source),
                  original_source_sha256=ORIGINAL_SHA256, patched_source_sha256=PATCHED_SHA256,
                  patch_sha256=sha256(patch), packages=packages)
    provenance.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Applied SI #4830: {source} ({PATCHED_SHA256})", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    args = parser.parse_args()
    apply(args.patch, args.provenance)
