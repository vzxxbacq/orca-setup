"""Check meaningful network-policy outcomes for isolated executor modes."""

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GatewayRulesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        (self.directory / "allow.tsv").write_text("git\t172.20.1.10/32\ttcp\t443\n")
        self.policy = ("proxy_type=socks5\nproxy_address=192.0.2.20\nproxy_port=1080\n"
                       "dns_address=1.1.1.1\ndns_transport=https\ndns_tls_name=cloudflare-dns.com\n"
                       "executor_dns=\ncontrol_subnet=172.30.70.0/24\nproxy_auth_file=\n")
        (self.directory / "policy.env").write_text(self.policy)

    def tearDown(self):
        self.temporary.cleanup()

    def rules(self, mode):
        (self.directory / "executor-policy.env").write_text(self.policy + "executor_mode=" + mode + "\n")
        return subprocess.check_output(["bash", str(ROOT / "docker/gateway.sh"), "rules", "executor", str(self.directory)], text=True)

    def test_blocked_mode_has_no_general_public_allow(self):
        rules = self.rules("blocked")
        self.assertNotIn("--to-ports 12345", rules)
        self.assertNotIn("-A OUTPUT -j ACCEPT", rules)
        self.assertIn("-A OUTPUT -p tcp -d 172.20.1.10/32 --dport 443 -j ACCEPT", rules)

    def test_proxy_mode_redirects_public_tcp_but_not_unlisted_private_destinations(self):
        rules = self.rules("proxy")
        nat, filtering, _ = rules.split("COMMIT")
        private = str(10) + ".0.0.0/8"
        self.assertLess(nat.index("-A OUTPUT -d " + private + " -j RETURN"), nat.index("--to-ports 12345"))
        self.assertIn("-A OUTPUT -p tcp -d 192.0.2.20/32 --dport 1080 -j ACCEPT", filtering)
        self.assertNotIn("-A OUTPUT -j ACCEPT", filtering)

    def test_direct_mode_allows_public_after_private_exceptions_and_denies(self):
        rules = self.rules("direct")
        _, filtering, _ = rules.split("COMMIT")
        private = str(10) + ".0.0.0/8"
        allowed = filtering.index("-A OUTPUT -p tcp -d 172.20.1.10/32 --dport 443 -j ACCEPT")
        denied = filtering.index("-A OUTPUT -d " + private + " -j REJECT")
        public = filtering.index("-A OUTPUT -j ACCEPT")
        self.assertLess(allowed, denied)
        self.assertLess(denied, public)


if __name__ == "__main__":
    unittest.main()

class InternalSshRulesTests(GatewayRulesTests):
    def test_mutual_ssh_is_opt_in_and_bypasses_only_peer_port(self):
        self.assertNotIn('--dport 2222', self.rules('blocked'))
        self.policy += 'internal_ssh=yes\n'
        (self.directory / 'policy.env').write_text(self.policy)
        for mode in ('blocked', 'direct', 'proxy'):
            rules = self.rules(mode)
            self.assertIn('-A INPUT -p tcp -s 172.30.70.2/32 -d 172.30.70.3/32 --dport 2222 -j ACCEPT', rules)
            self.assertIn('-A OUTPUT -p tcp -d 172.30.70.2/32 --dport 2222 -j ACCEPT', rules)
        rules = subprocess.check_output(['bash',str(ROOT/'docker/gateway.sh'),'rules','orca',str(self.directory)],text=True)
        self.assertIn('-A OUTPUT -p tcp -d 172.30.70.3/32 --dport 2222 -j RETURN',rules)
