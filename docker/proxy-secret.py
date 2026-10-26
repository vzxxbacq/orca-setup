#!/usr/bin/env python3
"""Publish/check proxy authentication via stdin. No authentication value is printed or passed as an argument."""

import hmac
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

DESTINATION = Path("/run/secrets/orca_proxy_auth")


def read_auth(stream):
    raw = stream.read(4097)
    if len(raw) > 4096:
        raise ValueError("authentication input is too large")
    auth = json.loads(raw)
    if not isinstance(auth, dict) or set(auth) != {"username", "password"}:
        raise ValueError("invalid authentication fields")
    if not all(isinstance(value, str) and 1 <= len(value) <= 255 and
               all(32 <= ord(char) <= 126 for char in value) for value in auth.values()):
        raise ValueError("invalid authentication values")
    return json.dumps(auth, sort_keys=True, separators=(",", ":")).encode("ascii")


def matches(path, desired):
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077:
            return False
        return hmac.compare_digest(path.read_bytes(), desired)
    except FileNotFoundError:
        return False


def publish(path, desired):
    if matches(path, desired):
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as output:
        temporary = output.name
        try:
            os.fchmod(output.fileno(), 0o600)
            output.write(desired)
            output.close()
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("check", "write"):
        raise ValueError("invalid operation")
    desired = read_auth(sys.stdin.buffer)
    if sys.argv[1] == "check":
        return 0 if matches(DESTINATION, desired) else 1
    if os.getuid() != 0:
        raise ValueError("the private publisher runs as container root")
    publish(DESTINATION, desired)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError):
        print("proxy authentication operation failed (values hidden)", file=sys.stderr)
        sys.exit(1)
