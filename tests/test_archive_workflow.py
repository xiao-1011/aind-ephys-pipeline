"""Safety tests runnable without cluster/SpikeInterface dependencies."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import archive_session
import arrhenius_batch


class ArchiveSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def archive(self, entries):
        path = self.root / "test.tar"
        with tarfile.open(path, "w") as tar:
            for name, data, kind in entries:
                info = tarfile.TarInfo(name)
                info.type = kind
                if kind == tarfile.REGTYPE:
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
                else:
                    info.linkname = "/etc/passwd"
                    tar.addfile(info)
        return path

    def verify(self, archive):
        stage = self.root / "stage"
        stage.mkdir()
        return archive_session.restore_verify(archive, stage)

    def test_verified_content_round_trip(self):
        data = b"corrected recording"
        manifest = {"files": {"data.bin": {"size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}}
        archive = self.archive([("session/archive_manifest.json", json.dumps(manifest).encode(), tarfile.REGTYPE),
                                ("session/data.bin", data, tarfile.REGTYPE)])
        with patch.object(archive_session, "verify_bundle") as check:
            self.assertEqual(self.verify(archive), manifest)
            check.assert_called_once()

    def test_corrupt_content_never_passes_restore_check(self):
        manifest = {"files": {"data.bin": {"size": 3, "sha256": hashlib.sha256(b"abc").hexdigest()}}}
        archive = self.archive([("session/archive_manifest.json", json.dumps(manifest).encode(), tarfile.REGTYPE),
                                ("session/data.bin", b"bad", tarfile.REGTYPE)])
        with patch.object(archive_session, "verify_bundle") as check:
            with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                self.verify(archive)
            check.assert_not_called()

    def test_rejects_path_traversal(self):
        with self.assertRaisesRegex(RuntimeError, "Unsafe archive member"):
            self.verify(self.archive([("session/../../outside", b"bad", tarfile.REGTYPE)]))

    def test_rejects_symlinks(self):
        with self.assertRaisesRegex(RuntimeError, "Unsupported archive member"):
            self.verify(self.archive([("session/link", b"", tarfile.SYMTYPE)]))

    def test_rejects_duplicate_members(self):
        with self.assertRaisesRegex(RuntimeError, "Duplicate archive member"):
            self.verify(self.archive([("session/data", b"a", tarfile.REGTYPE),
                                      ("session/data", b"b", tarfile.REGTYPE)]))

    def test_cleanup_only_deletes_owned_session(self):
        root = self.root / "work"
        target = root / "cohort/date/session"
        target.mkdir(parents=True)
        (target / "data").write_text("temporary")
        protected = self.root / "raw/cohort/date/session"
        protected.mkdir(parents=True)
        with self.assertRaises(RuntimeError):
            arrhenius_batch.remove_owned(protected, root, "cohort/date/session")
        with self.assertRaises(RuntimeError):
            arrhenius_batch.remove_owned(root, root, ".")
        arrhenius_batch.remove_owned(target, root, "cohort/date/session")
        self.assertFalse(target.exists())
        self.assertTrue(protected.exists())
        self.assertTrue(root.exists())

    def test_cleanup_rejects_external_symlink(self):
        root = self.root / "work"
        (root / "cohort/date").mkdir(parents=True)
        outside = self.root / "raw"
        outside.mkdir()
        target = root / "cohort/date/session"
        target.symlink_to(outside)
        with self.assertRaises(RuntimeError):
            arrhenius_batch.remove_owned(target, root, "cohort/date/session")
        self.assertTrue(outside.exists())


if __name__ == "__main__":
    unittest.main()
