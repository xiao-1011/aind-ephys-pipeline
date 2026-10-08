"""Host-side checks for replay parameter extraction and strict patch preconditions."""
import json
from pathlib import Path
import shlex
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import apply_si4830
from verify_curation_si4830 import task_params


class BackportWorkflowTests(unittest.TestCase):
    def test_preserves_retained_task_parameters(self):
        params = {"unitrefine": {"noise_neural_classifier": "org/model"}, "qc_thresholds": {"snr": {"greater": 5}}}
        with tempfile.TemporaryDirectory() as directory:
            task = Path(directory)
            (task / ".command.sh").write_text("cd capsule/code\n    ./run --params " + shlex.quote(json.dumps(params)) + "\n")
            self.assertEqual(task_params(task), params)

    def test_rejects_ambiguous_or_extra_replay_commands(self):
        for command in ("./run --params '{}' --other value", "./run --params '{}'\n./run --params '{}'", "./run"):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as directory:
                task = Path(directory)
                (task / ".command.sh").write_text(command)
                with self.assertRaises(RuntimeError):
                    task_params(task)

    def test_rejects_wrong_package_version_before_modification(self):
        distribution = Mock(version="0.106.0")
        with patch.object(apply_si4830.metadata, "distribution", return_value=distribution), \
                patch.object(apply_si4830.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "Expected SpikeInterface"):
                apply_si4830.apply(Path("patch"), Path("provenance"))
            run.assert_not_called()

    def test_rejects_modified_source_before_modification(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "train_manual_curation.py"
            source.write_text("unexpected source")
            distribution = Mock(version="0.105.0")
            distribution.locate_file.return_value = source
            with patch.object(apply_si4830.metadata, "distribution", return_value=distribution), \
                    patch.object(apply_si4830.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "Unexpected source"):
                    apply_si4830.apply(Path("patch"), Path("provenance"))
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
