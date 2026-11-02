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
