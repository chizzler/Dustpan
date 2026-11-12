import os
import pathlib
import tempfile
import unittest
from unittest import mock

from dustpan import config
from dustpan.config import safe_url


class SafeUrlTest(unittest.TestCase):
    def test_https_anywhere(self):
        self.assertTrue(safe_url("https://todo.example.com"))
        self.assertTrue(safe_url("https://203.0.113.5:8443/"))

    def test_plain_http_only_to_this_machine(self):
        self.assertTrue(safe_url("http://localhost:8080"))
        self.assertTrue(safe_url("http://127.0.0.1:8080"))
        self.assertTrue(safe_url("http://[::1]:8080"))
        self.assertFalse(safe_url("http://todo.example.com"))
        self.assertFalse(safe_url("http://192.168.1.10:8080"))
        self.assertFalse(safe_url("http://localhost.example.com"))

    def test_other_schemes_and_junk(self):
        self.assertFalse(safe_url("ftp://localhost"))
        self.assertFalse(safe_url("todo.example.com"))
        self.assertFalse(safe_url("https://"))


class LoadTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.folder.name) / "config"
        patcher = mock.patch.dict(os.environ, {"DUSTPAN_CONFIG": str(self.path)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self.folder.cleanup()

    def test_reads_url_and_token(self):
        self.path.write_text("# real server\nOPENTODO_URL=https://todo.example.com\nOPENTODO_TOKEN=ot_abc\n")
        cfg = config.load()
        self.assertEqual((cfg.url, cfg.token), ("https://todo.example.com", "ot_abc"))

    def test_refuses_plain_http_to_another_machine(self):
        self.path.write_text("OPENTODO_URL=http://todo.example.com\nOPENTODO_TOKEN=ot_abc\n")
        with self.assertRaisesRegex(config.ConfigMissing, "https"):
            config.load()

    def test_load_optional_supports_standalone_when_missing_or_blank(self):
        self.assertEqual(config.load_optional(), (None, None))
        self.path.write_text("# standalone\nOPENTODO_URL=\nOPENTODO_TOKEN=\n")
        self.assertEqual(config.load_optional(), (None, None))

    def test_load_optional_reports_warning_without_blocking_startup_when_malformed(self):
        self.path.write_text("OPENTODO_URL=https://todo.example.com\n")
        cfg, warning = config.load_optional()
        self.assertIsNone(cfg)
        self.assertIn("OPENTODO_TOKEN", warning)
        self.path.write_text("OPENTODO_URL=http://todo.example.com\nOPENTODO_TOKEN=ot_abc\n")
        cfg, warning = config.load_optional()
        self.assertIsNone(cfg)
        self.assertIn("https", warning)

    def test_save_and_clear_keep_private_permissions_and_comments(self):
        self.path.write_text("# my comment\nOTHER_KEY=keep\n")
        config.save(config.Config("https://todo.example.com", "ot_secret"))
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        cfg, warning = config.load_optional()
        self.assertIsNone(warning)
        self.assertEqual(cfg, config.Config("https://todo.example.com", "ot_secret"))
        self.assertIn("# my comment", self.path.read_text())
        self.assertIn("OTHER_KEY=keep", self.path.read_text())

        config.clear()
        self.assertEqual(config.load_optional(), (None, None))
        self.assertIn("OTHER_KEY=keep", self.path.read_text())

        self.path.unlink()
        config.save(config.Config("http://localhost:8080", "ot_dev"))
        config.clear()
        self.assertFalse(self.path.exists())
        self.assertEqual(config.load_optional(), (None, None))

    def test_validate_refuses_multiline_or_empty_values(self):
        for url, token in [("", "ot"), ("https://todo.example.com", ""), ("https://a.com\nx", "ot"), ("https://a.com", "ot\nx")]:
            with self.assertRaises(config.ConfigMissing):
                config.validate(url, token)
