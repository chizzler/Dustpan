"""Standalone startup, CLI behavior, optional sync controls and Settings dialog."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gtk  # noqa: E402

from dustpan import config, trash  # noqa: E402
from dustpan.store import Store  # noqa: E402
from dustpan.writes import Writer  # noqa: E402

DESKTOP_DIR = Path(__file__).resolve().parents[1]
HAS_DISPLAY = bool(Gtk.init_check() and Gdk.Display.get_default() is not None)
if HAS_DISPLAY:
    Adw.init()


class StandaloneCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {
            **os.environ,
            "DUSTPAN_CONFIG": str(self.root / "missing-config"),
            "DUSTPAN_DATA": str(self.root / "data"),
        }

    def test_tree_works_without_server_config(self):
        (self.root / "data").mkdir(parents=True, exist_ok=True)
        store = Store(self.root / "data" / "dustpan.db")
        try:
            writer = Writer(store)
            pid = writer.add_project("Local")
            writer.add_task("Buy coffee", project_id=pid)
        finally:
            store.close()
        proc = subprocess.run(
            [sys.executable, "-m", "dustpan", "tree"],
            cwd=DESKTOP_DIR, env=self.env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("# Local", proc.stdout)
        self.assertIn("- Buy coffee", proc.stdout)

    def test_sync_cli_reports_clean_message_when_unconfigured(self):
        proc = subprocess.run(
            [sys.executable, "-m", "dustpan", "sync"],
            cwd=DESKTOP_DIR, env=self.env, capture_output=True, text=True, check=False,
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("OpenTodo sync is not configured", proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)


@unittest.skipUnless(HAS_DISPLAY, "GTK display not available")
class StandaloneWindowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        env = patch.dict(os.environ, {
            "DUSTPAN_CONFIG": str(self.root / "config"),
            "DUSTPAN_DATA": str(self.root / "data"),
        })
        env.start()
        self.addCleanup(env.stop)

    def test_window_opens_standalone_without_sync_controls_and_supports_settings_and_local_trash(self):
        from dustpan.app import TRASH, Window
        from dustpan.dialogs import SettingsDialog

        window = Window(None, cfg=None)
        self.addCleanup(window.store.close)
        self.addCleanup(window.destroy)
        mapped = patch.object(window, "get_mapped", return_value=True)
        mapped.start()
        self.addCleanup(mapped.stop)

        self.assertIsNone(window.cfg)
        self.assertIsNone(window.events)
        self.assertFalse(window.refresh_button.get_visible())
        self.assertTrue(window.settings_button.get_visible())
        self.assertEqual(window.title.get_subtitle() or "", "")

        # Editing locally does not start sync or show any sync status.
        tid = window.writer.add_task("Local task")
        window.after_edit()
        self.assertFalse(window.syncing)
        self.assertEqual(window.sync_timer, 0)
        self.assertEqual(window.title.get_subtitle() or "", "")

        # Settings dialog builds cleanly in standalone mode and updates local preferences.
        dialog = SettingsDialog(window)
        self.assertEqual(dialog.connect_button.get_label(), "Connect to OpenTodo")
        self.assertIsNone(dialog.disconnect_button)
        dialog._set_pref("time_format", "24h")
        dialog._set_pref("reminder_default_timed", -30)
        self.assertEqual(window.time_format, "24h")
        self.assertEqual(window.store.rows("user_prefs")["me"].get("reminder_default_timed"), "-30")

        # Trash shows local permanent-retention state and purges locally.
        window.delete_task(tid)
        self.assertEqual(len(window.trash), 1)
        window.selected = TRASH
        window.refresh_view()
        trash.purge_local(window.store, [("task", tid)])
        window.refresh_view()
        self.assertEqual(window.trash, [])
        self.assertEqual(window.store.rows("task"), {})

        # Live connect/disconnect toggles sync UI while preserving local data.
        keep = window.writer.add_task("Keep across disconnect")
        window.refresh_view()
        with patch.object(window, "_start_events"), patch.object(window, "sync"):
            window.connect_sync(config.Config("https://todo.example.com", "ot_tok"))
            self.assertTrue(window.refresh_button.get_visible())
        window.disconnect_sync()
        self.assertIsNone(window.cfg)
        self.assertFalse(window.refresh_button.get_visible())
        self.assertEqual(window.title.get_subtitle() or "", "")
        self.assertIn(keep, window.store.rows("task"))


if __name__ == "__main__":
    unittest.main()
