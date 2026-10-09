"""Pinned-model local verification must reject unpinned or changed bytes."""

import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ks4_motion_trace_models import EXPECTED, TEST, check_models


class LocalModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.user = Path(self.temp.name)
        self.root = self.user / TEST
        self.root.mkdir(parents=True)
        self.models = {}
        for key, (repo, revision) in EXPECTED.items():
            origin = self.user / "reference" / key
            cache = self.root / "hf-cache/hub" / ("models--" + repo.replace("/", "--"))
            for directory in (origin, cache / "snapshots" / revision):
                directory.mkdir(parents=True)
                (directory / "model.skops").write_bytes(key.encode())
            (cache / "refs").mkdir()
            (cache / "refs/main").write_text(revision + "\n")
            self.models[key] = {"repo": repo, "revision": revision, "snapshot": str(origin),
                                "files": {"model.skops": hashlib.sha256(key.encode()).hexdigest()}}
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        (self.root / "model_provenance.json").write_text(json.dumps(self.models))

    def test_matching_pinned_model_files_pass(self):
        result = check_models(self.user)
        self.assertEqual(set(result), set(EXPECTED))
        self.assertTrue(all(m["source_and_cache_sha256_match"] for m in result.values()))

    def test_modified_cached_bytes_fail_closed(self):
        key = "noise_neural_classifier"
        repo, revision = EXPECTED[key]
        target = self.root / "hf-cache/hub" / ("models--" + repo.replace("/", "--")) / "snapshots" / revision / "model.skops"
        target.write_bytes(b"modified")
        with self.assertRaises(AssertionError):
            check_models(self.user)

    def test_wrong_revision_or_cached_ref_fails(self):
        self.models["noise_neural_classifier"]["revision"] = "f" * 40
        self.save()
        with self.assertRaises(AssertionError):
            check_models(self.user)
        self.models["noise_neural_classifier"]["revision"] = EXPECTED["noise_neural_classifier"][1]
        self.save()
        repo, _ = EXPECTED["noise_neural_classifier"]
        (self.root / "hf-cache/hub" / ("models--" + repo.replace("/", "--")) / "refs/main").write_text("f" * 40)
        with self.assertRaises(AssertionError):
            check_models(self.user)


if __name__ == "__main__":
    unittest.main()
