#!/usr/bin/env python3
"""Initialize deployment-only SSH identities locally; never print or export private material."""
import ipaddress
import os
from pathlib import Path
import re
import subprocess
import sys


def write(path, data):
    if path.is_symlink():
        raise ValueError('Identity files must not be symbolic links.')
    if path.exists() and path.read_text() == data:
        return
    temporary = path.with_suffix('.new')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(data)
    temporary.replace(path)


def initialize(root, user, orca, executor):
    if not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_-]*[$]?', user):
        raise ValueError('Invalid SSH user.')
    addresses = dict(orca=str(ipaddress.IPv4Address(orca)), executor=str(ipaddress.IPv4Address(executor)))
    os.umask(0o077)
    for role in addresses:
        directory = root / role
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if directory.is_symlink() or directory.stat().st_uid != os.getuid():
            raise ValueError('Invalid identity directory.')
        directory.chmod(0o700)
        for name in ('host', 'client'):
            path = directory / name
            if path.is_symlink():
                raise ValueError('Identity must not be a symbolic link.')
            if not path.exists():
                subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            public = subprocess.check_output(['ssh-keygen', '-y', '-f', str(path)], stderr=subprocess.DEVNULL).decode()
            write(directory / (name + '.pub'), public)
    for role, peer in (('orca', 'executor'), ('executor', 'orca')):
        directory = root / role
        write(directory / 'authorized_keys', (root / peer / 'client.pub').read_text())
        write(directory / 'known_hosts', peer + ' ' + (root / peer / 'host.pub').read_text())
        write(directory / 'client.conf', f'''Host {peer}
    HostName {addresses[peer]}
    HostKeyAlias {peer}
    Port 2222
    User {user}
    IdentityFile /run/orca-ssh/client
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking yes
    UserKnownHostsFile /run/orca-ssh/known_hosts
    GlobalKnownHostsFile /dev/null
    ForwardAgent no
''')
        write(directory / 'sshd.conf', f'''Port 2222
ListenAddress {addresses[role]}
HostKey /run/orca-ssh/host
PidFile /tmp/orca-sshd.pid
AuthorizedKeysFile /run/orca-ssh/authorized_keys
AllowUsers {user}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
DisableForwarding yes
PermitTunnel no
X11Forwarding no
PermitUserEnvironment no
PermitUserRC no
StrictModes yes
PrintMotd no
LogLevel ERROR
Subsystem sftp internal-sftp
''')


if __name__ == '__main__':
    try:
        initialize(Path(sys.argv[1]), *sys.argv[2:])
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit('Internal SSH initialization failed; identity values were not printed.') from None
