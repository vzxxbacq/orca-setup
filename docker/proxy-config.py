#!/usr/bin/env python3
"""Build a private in-memory-filesystem proxy config. Never print authentication data."""

import ipaddress
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


def load_auth(path):
    metadata = path.stat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077:
        raise ValueError("authentication file must be root-owned and owner-only")
    if metadata.st_size > 4096:
        raise ValueError("authentication file is too large")
    auth = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(auth, dict) or set(auth) != {"username", "password"}:
        raise ValueError("authentication file has unexpected fields")
    for value in auth.values():
        if not isinstance(value, str) or not 1 <= len(value) <= 255 or any(not 32 <= ord(char) <= 126 for char in value):
            raise ValueError("authentication values require 1-255 printable ASCII characters")
    return auth


def render(policy, auth=None):
    address = str(ipaddress.IPv4Address(policy["proxy_address"]))
    port = int(policy["proxy_port"])
    kind = policy["proxy_type"]
    if not 1 <= port <= 65535 or kind not in ("socks5", "http-connect"):
        raise ValueError("invalid proxy policy")
    lines = ['base { log_debug = off; log_info = off; log = "stderr"; daemon = off; redirector = iptables; }',
             'redsocks {', '  local_ip = 127.0.0.1; local_port = 12345;',
             f'  ip = {address}; port = {port}; type = {kind};']
    if auth:
        # JSON quoting is also valid for the printable ASCII strings accepted above; config syntax cannot be injected.
        lines.extend([f'  login = {json.dumps(auth["username"])};', f'  password = {json.dumps(auth["password"])};'])
    return "\n".join(lines + ['}', ''])


def main():
    policy = {}
    for line in Path(sys.argv[1]).read_text().splitlines():
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            policy[key] = value
    auth = load_auth(Path("/run/secrets/orca_proxy_auth")) if policy.get("proxy_auth_file") else None
    destination = Path(sys.argv[2])
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as output:
        temporary = output.name
        try:
            os.fchmod(output.fileno(), 0o600)
            output.write(render(policy, auth))
            output.close()
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError):
        print("proxy configuration failed; verify the policy and external owner-only authentication file", file=sys.stderr)
        sys.exit(1)
