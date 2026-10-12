#!/usr/bin/env python3
"""Verify the *pinned model bytes* in both local snapshots without an API call.

This proves that the replay's cached classifiers match their previously
recorded revisions and SHA-256 file manifest. It does not check current HEAD
on Hugging Face; API calls are rate-limited on the shared cluster IP.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re


EXPECTED = {
    "noise_neural_classifier": ("SpikeInterface/UnitRefine_noise_neural_classifier", "280cd07ff8310286ded5c0cfdb382e92e2a43a98"),
    "sua_mua_classifier": ("SpikeInterface/UnitRefine_sua_mua_classifier", "9ee216e7e0e7dbf0778cb07a8d1753700dbbad3b"),
}
TEST = "baseline_pilots/ks4_native_motion_trace_test_20261008"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_models(user_root):
    user_root = Path(user_root).resolve()
    test_root = user_root / TEST
    manifest = test_root / "model_provenance.json"
    models = json.loads(manifest.read_text())
    assert set(models) == set(EXPECTED), "Model list changed"
    verified = {}
    for key, model in models.items():
        repo, revision = EXPECTED[key]
        assert (model["repo"], model["revision"]) == (repo, revision), (key, "revision changed")
        assert re.fullmatch(r"[0-9a-f]{40}", revision)
        assert model["files"] and all(re.fullmatch(r"[0-9a-f]{64}", h) for h in model["files"].values())
        origin = Path(model["snapshot"])
        cache_root = test_root / "hf-cache/hub" / ("models--" + repo.replace("/", "--"))
        cached = cache_root / "snapshots" / revision
        ref = cache_root / "refs/main"
        assert ref.read_text().strip() == revision, (repo, "cached main ref differs")
        assert origin.is_dir() and cached.is_dir(), (repo, "snapshot missing")
        for snapshot in (origin, cached):
            assert not snapshot.is_symlink(), snapshot
            existing = {str(p.relative_to(snapshot)) for p in snapshot.rglob("*") if p.is_file()}
            assert existing == set(model["files"]), (repo, snapshot, "file set changed", existing ^ set(model["files"]))
            for name, expected_hash in model["files"].items():
                path = snapshot / name
                assert path.is_file() and sha256(path) == expected_hash, (repo, path, "contents changed")
        verified[key] = {"repo": repo, "pinned_revision": revision, "file_count": len(model["files"]),
                         "source_and_cache_sha256_match": True}
    return verified


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user-root", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(check_models(args.user_root), indent=2), flush=True)
