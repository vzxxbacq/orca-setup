"""Authentication stays in the gateway's private filesystem and never in host-rendered configuration."""

import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from test_execution import load_module

proxy = load_module("proxy_config", "proxy-config.py")


class ProxyConfigTests(unittest.TestCase):
    @staticmethod
    def auth_file(values, uid=0, permissions=0o600):
        result = Mock()
        text = json.dumps(values)
        result.stat.return_value = SimpleNamespace(st_mode=stat.S_IFREG | permissions, st_uid=uid, st_size=len(text))
        result.read_text.return_value = text
        return result

    def test_owner_only_authentication_and_config_quoting(self):
        auth = {"username": 'test"user', "password": 'fake\\pass"value'}
        loaded = proxy.load_auth(self.auth_file(auth))
        config = proxy.render({"proxy_type": "socks5", "proxy_address": "192.0.2.20", "proxy_port": "1080"}, loaded)
        self.assertIn('login = "test\\"user";', config)
        self.assertIn('password = "fake\\\\pass\\"value";', config)

    def test_unsafe_file_permissions_or_owner_are_rejected_before_reading(self):
        for uid, mode in ((1000, 0o600), (0, 0o644), (0, 0o640)):
            source = self.auth_file({"username": "test", "password": "fake"}, uid, mode)
            with self.assertRaises(ValueError):
                proxy.load_auth(source)
            source.read_text.assert_not_called()

    def test_invalid_or_injected_authentication_is_rejected(self):
        for auth in ({"username": "test", "password": "fake\n}; bad = value;"},
                     {"username": "", "password": "fake"},
                     {"username": "test", "password": "x" * 256},
                     {"username": "test", "password": "fake", "extra": True}):
            with self.assertRaises(ValueError):
                proxy.load_auth(self.auth_file(auth))

    def test_unauthenticated_endpoint_needs_no_secret(self):
        config = proxy.render({"proxy_type": "http-connect", "proxy_address": "192.0.2.20", "proxy_port": "8080"})
        self.assertNotIn("password", config)
        self.assertNotIn("login", config)

    def test_config_errors_do_not_print_policy_values_or_tracebacks(self):
        with tempfile.TemporaryDirectory() as directory:
            policy = Path(directory) / "policy.env"
            policy.write_text("proxy_address=FAKE-PRIVATE-SENTINEL\nproxy_type=socks5\nproxy_port=1080\n")
            script = Path(__file__).resolve().parents[2] / "docker/proxy-config.py"
            result = subprocess.run([sys.executable, str(script), str(policy), str(Path(directory) / "output")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("FAKE-PRIVATE-SENTINEL", result.stdout + result.stderr)
            self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
