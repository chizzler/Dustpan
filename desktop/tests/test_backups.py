"""Exercise the backup script without SSH or the user's real data."""

import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest


class BackupTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.script = root / "pull-backups.sh"
        self.script.write_text((Path(__file__).resolve().parents[2] / "deploy/pull-backups.sh").read_text())
        binaries = root / "bin"
        binaries.mkdir()
        rsync = binaries / "rsync"
        rsync.write_text('#!/bin/sh\n: > "$DUSTPAN_TEST_MARKER"\nexit "$DUSTPAN_TEST_RSYNC_EXIT"\n')
        rsync.chmod(0o755)
        self.data = root / "data/dustpan"
        self.data.mkdir(parents=True)
        self.marker = root / "rsync-ran"
        self.env = dict(os.environ, HOST="test.invalid", XDG_DATA_HOME=str(root / "data"),
                        PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                        DUSTPAN_TEST_MARKER=str(self.marker), DUSTPAN_TEST_RSYNC_EXIT="0")

    def test_ssh_failure_still_saves_a_readable_local_snapshot(self):
        with sqlite3.connect(self.data / "dustpan.db") as db:
            db.execute("CREATE TABLE example (value TEXT)")
            db.execute("INSERT INTO example VALUES ('offline edit')")
        self.env["DUSTPAN_TEST_RSYNC_EXIT"] = "255"
        result = subprocess.run(["bash", str(self.script)], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 255)
        snapshots = list((self.data / "backups/client").glob("*.db"))
        self.assertEqual(len(snapshots), 1)
        with sqlite3.connect(snapshots[0]) as db:
            self.assertEqual(db.execute("SELECT value FROM example").fetchone(), ("offline edit",))

    def test_local_backup_failure_still_attempts_server_copy_and_reports_failure(self):
        (self.data / "dustpan.db").write_text("not a SQLite database")
        result = subprocess.run(["bash", str(self.script)], env=self.env, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.marker.exists())
