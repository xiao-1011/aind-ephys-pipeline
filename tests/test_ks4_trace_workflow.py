"""Host-side safeguards for downstream-only capsule replay."""
import json
from pathlib import Path
import shlex
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from ks4_motion_trace_replay import capsule_source, link, sha256


class TraceReplayTests(unittest.TestCase):
    def task(self, root, key, repo, group, params=None):
        task = root / "aa" / key
        (task / "capsule/code").mkdir(parents=True)
        data = task / "capsule/data"
        data.mkdir()
        if repo == "postprocessing":
            (data / f"job_{group}.json").write_text(json.dumps({"recording_name": f"recording_group{group}"}))
        else:
            (data / f"postprocessed_recording_group{group}.zarr").mkdir()
        params = params or {"use_motion_corrected": False}
        (task / ".command.sh").write_text(f"clone_repo https://github.com/AllenNeuralDynamics/aind-ephys-{repo} pinned\n./run --params {shlex.quote(json.dumps(params))}\n")
        return task

    def test_selects_postprocessing_job_for_requested_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.task(root, "wrong", "postprocessing", 2)
            wanted = self.task(root, "right", "postprocessing", 0)
            code, params = capsule_source(root, "postprocessing", 0)
            self.assertEqual(code, wanted / "capsule/code")
            self.assertFalse(json.loads(params)["use_motion_corrected"])

    def test_selects_curation_by_analyzer_group(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.task(root, "wrong", "curation", 3)
            wanted = self.task(root, "right", "curation", 1)
            self.assertEqual(capsule_source(root, "curation", 1)[0], wanted / "capsule/code")

    def test_missing_group_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(RuntimeError):
                capsule_source(Path(directory), "curation", 0)

    def test_ambiguous_commands_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            task = self.task(root, "task", "curation", 0)
            with (task / ".command.sh").open("a") as f:
                f.write("./run --params '{}'\n")
            with self.assertRaisesRegex(AssertionError, "Ambiguous"):
                capsule_source(root, "curation", 0)

    def test_does_not_overwrite_files_or_broken_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.write_text("retained work")
            destination = root / "destination"
            destination.symlink_to(root / "absent")
            with self.assertRaises(AssertionError):
                link(destination, source)
            self.assertTrue(destination.is_symlink())
            self.assertEqual(source.read_text(), "retained work")
            self.assertEqual(sha256(source), sha256(source))


if __name__ == "__main__":
    unittest.main()
