"""Only expected tar members may be extracted, with exact checksums."""

import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from dredge_trace_stage import extract_selected, selected_files


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.shanks = tuple(f"block0_imec0.ap_recording1_group{i}" for i in range(4))
        self.data = {"archive_provenance/active_params.json": b"{}",
                     "archive_provenance/capsule_versions.env": b"version\n"}
        for shank in self.shanks:
            self.data[f"preprocessed/{shank}.json"] = b"{}"
            self.data[f"recordings/{shank}/binary.json"] = b"corrected"
            self.data[f"postprocessed/{shank}.zarr/sorting/info.json"] = b"sorted"
        self.data["nwb/keep.nwb"] = b"do not extract"
        self.manifest = {"shanks": dict.fromkeys(self.shanks, {}), "files": {
            key: {"size": len(value), "sha256": hashlib.sha256(value).hexdigest()}
            for key, value in self.data.items()}}
        self.archive = self.root / "source.tar"
        with tarfile.open(self.archive, "w:") as tar:
            for key, value in self.data.items():
                info = tarfile.TarInfo("session/" + key)
                info.size = len(value)
                tar.addfile(info, io.BytesIO(value))

    def tearDown(self):
        self.temp.cleanup()

    def test_extracts_only_expected_and_verifies_hashes(self):
        dest = self.root / "stage"
        dest.mkdir()
        with tarfile.open(self.archive) as tar:
            result = extract_selected(tar, "session", dest, self.manifest)
        self.assertEqual(result["files"], len(self.data) - 1)
        self.assertFalse((dest / "nwb/keep.nwb").exists())
        self.assertEqual((dest / "recordings" / self.shanks[0] / "binary.json").read_bytes(), b"corrected")

    def test_changed_contents_fail_closed(self):
        self.manifest["files"][f"recordings/{self.shanks[0]}/binary.json"]["sha256"] = "0" * 64
        dest = self.root / "stage"
        dest.mkdir()
        with tarfile.open(self.archive) as tar, self.assertRaisesRegex(AssertionError, "checksum mismatch"):
            extract_selected(tar, "session", dest, self.manifest)

    def test_missing_shank_fails_before_extraction(self):
        del self.manifest["files"][f"recordings/{self.shanks[3]}/binary.json"]
        with self.assertRaises(AssertionError):
            selected_files(self.manifest)


if __name__ == "__main__":
    unittest.main()
