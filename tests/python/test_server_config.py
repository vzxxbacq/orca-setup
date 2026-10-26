"""Validate single-file server configuration without exposing inline proxy authentication."""

import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from test_execution import load_module

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("server_config", ROOT / "lib/server-config.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)
secret = load_module("proxy_secret", "proxy-secret.py")


class ServerConfigTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()
        self.path = self.directory / "server.toml"

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, content, mode=0o600):
        self.path.write_text(content)
        self.path.chmod(mode)
        return self.path

    def inline(self, extra=""):
        return self.write('[proxy]\naddress="192.0.2.20"\nusername="fixture"\npassword="FAKE-AUTH-SENTINEL"\n' + extra)

    def test_public_output_keeps_authentication_out_of_generated_settings(self):
        self.inline()
        result = subprocess.run([sys.executable, str(ROOT / "lib/server-config.py"), "public", str(self.path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("proxy_inline_auth\tyes", result.stdout)
        self.assertNotIn("FAKE-AUTH-SENTINEL", result.stdout + result.stderr)
        self.assertNotIn("fixture", result.stdout)

    def test_inline_auth_requires_caller_owned_private_file(self):
        self.inline()
        for mode in (0o644, 0o700):
            self.path.chmod(mode)
            with self.assertRaisesRegex(config.ConfigError, "mode 0600"):
                config.load(self.path)
        self.path.chmod(0o600)
        with patch.object(config.os, "getuid", return_value=os.getuid() + 1):
            with self.assertRaisesRegex(config.ConfigError, "caller-owned"):
                config.load(self.path)

    def test_syntax_errors_never_echo_toml_source_or_tracebacks(self):
        self.inline('bad = "FAKE-AUTH-SENTINEL\n')
        result = subprocess.run([sys.executable, str(ROOT / "lib/server-config.py"), "public", str(self.path)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("FAKE-AUTH-SENTINEL", result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_relative_paths_private_rules_and_limits_are_validated(self):
        self.write('[server]\nworkdir="./projects"\n[limits]\ncpus=2.5\npids_limit=256\n'
                   '[[executor.allow]]\ncidr="172.20.1.0/24"\nport=443\n')
        public, _ = config.load(self.path)
        self.assertEqual(public["workdir"], str(self.directory / "projects"))
        self.assertEqual(public["allow"], ["rule-1\t172.20.1.0/24\ttcp\t443"])
        self.assertIn("cpus=2.5", public["limits"])
        for invalid in ('[other]\nkey=1', '[server]\nimgae="typo"', '[limits]\ncpus=nan',
                        '[limits]\npids_limit=true', '[[executor.allow]]\ncidr="0.0.0.0/0"\nport=443',
                        '[[executor.allow]]\ncidr="172.20.1.1/24"\nport=443',
                        '[network]\nmode="isolated"', '[proxy]\naddress="proxy.example.com"',
                        '[server]\nimage_source="local"'):
            with self.subTest(invalid=invalid), self.assertRaises(config.ConfigError):
                config.load(self.write(invalid))

    def test_authentication_forms_are_exclusive_and_direct_proxy_is_rejected(self):
        self.inline('auth_file="./auth.json"\n')
        with self.assertRaisesRegex(config.ConfigError, "mutually exclusive"):
            config.load(self.path)
        with self.assertRaises(config.ConfigError):
            config.load(self.write('[network]\nmode="direct"\n[proxy]\naddress="192.0.2.20"'))
        with self.assertRaises(config.ConfigError):
            config.load(self.write('[proxy]\naddress="192.0.2.20"\nusername="fixture"'))

    def test_inline_checkout_policy_and_public_template(self):
        self.inline()
        (self.directory / "manifest").mkdir()
        (self.directory / "manifest/server-network.env").write_bytes((ROOT / "manifest/server-network.env").read_bytes())
        with patch.object(config, "ROOT", self.directory):
            with self.assertRaisesRegex(config.ConfigError, "ignored root orca.toml"):
                config.load(self.path)
        public, auth = config.load(ROOT / "orca.example.toml")
        self.assertIsNone(auth)
        self.assertEqual(public["network_mode"], "isolated")


class ProxySecretTests(unittest.TestCase):
    def test_private_comparison_requires_regular_root_owned_owner_only_file(self):
        desired = secret.read_auth(io.BytesIO(b'{"username":"fixture","password":"fake"}'))
        for uid, mode, expected in ((0, 0o600, True), (1000, 0o600, False),
                                    (0, 0o644, False), (0, stat.S_IFLNK | 0o600, False)):
            with self.subTest(uid=uid, mode=mode):
                path = Mock()
                path.lstat.return_value = SimpleNamespace(st_uid=uid, st_mode=stat.S_IFREG | mode)
                path.read_bytes.return_value = desired
                self.assertEqual(secret.matches(path, desired), expected)
        with self.assertRaises(ValueError):
            secret.read_auth(io.BytesIO(b'{"username":"fixture","password":"fake","extra":1}'))

    def test_atomic_publication_is_owner_only_and_preserves_unchanged_data(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "auth"
            desired = secret.read_auth(io.BytesIO(b'{"username":"fixture","password":"fake"}'))
            secret.publish(path, desired)
            self.assertEqual(json.loads(path.read_bytes()), {"username": "fixture", "password": "fake"})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            # The filesystem belongs to the regular test user; substitute only the container-root ownership check.
            with patch.object(secret, "matches", wraps=lambda item, value: item.read_bytes() == value):
                before = path.stat().st_mtime_ns
                secret.publish(path, desired)
                self.assertEqual(path.stat().st_mtime_ns, before)


if __name__ == "__main__":
    unittest.main()
