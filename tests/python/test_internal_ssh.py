"""Configuration and deployment-only identities, without importing user credentials."""
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
def load(name, path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
config=load('ssh_config_validation','lib/server-config.py')
identity=load('ssh_identity','docker/ssh-identity.py')

class InternalSshTests(unittest.TestCase):
    def test_requires_boolean_and_isolated_network(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'settings.toml'
            for value,mode in [('true','direct'),('"yes"','isolated')]:
                path.write_text(f'[server]\ninternal_ssh={value}\n[network]\nmode="{mode}"\n')
                with self.assertRaises(config.ConfigError): config.load(path)
            path.write_text('[server]\ninternal_ssh=true\n[network]\nmode="isolated"\n[proxy]\naddress="192.0.2.20"\n')
            public,_=config.load(path)
            self.assertEqual(public['internal_ssh'],'yes')

    def test_identities_are_separate_persistent_and_strictly_pinned(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            old_mask=os.umask(0o077)
            try:
                identity.initialize(root,'fixture','172.29.90.2','172.29.90.3')
                first=(root/'orca/host.pub').read_text()
                self.assertNotEqual(first,(root/'executor/host.pub').read_text())
                identity.initialize(root,'fixture','172.29.90.2','172.29.90.3')
                self.assertEqual(first,(root/'orca/host.pub').read_text())
                self.assertEqual(stat.S_IMODE((root/'orca/client').stat().st_mode),0o600)
                self.assertEqual((root/'orca/authorized_keys').read_text(),(root/'executor/client.pub').read_text())
                self.assertIn('StrictHostKeyChecking yes',(root/'orca/client.conf').read_text())
                self.assertIn('DisableForwarding yes',(root/'orca/sshd.conf').read_text())
            finally:
                os.umask(old_mask)
