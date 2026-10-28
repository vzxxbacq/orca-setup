"""Disposable namespace-isolated SSH/shell checks. No host profile or production identity is mounted."""
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
IMAGE = os.environ['ORCA_SETUP_TEST_IMAGE']
PREFIX = 'orca-ssh-test-' + uuid.uuid4().hex[:10]


def docker(*args, timeout=45):
    return subprocess.run(['docker', *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)


def checked(*args):
    result = docker(*args)
    if result.returncode:
        raise AssertionError('Fixture Docker action failed: ' + result.stderr[:1200])
    return result.stdout.strip()


def eventually(check):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.3)
    raise AssertionError('Fixture did not become ready')


if os.getuid() == 0:
    raise SystemExit('Run as a regular Docker user.')
with tempfile.TemporaryDirectory(prefix=PREFIX) as temporary:
    root = Path(temporary)
    identities = root / 'identities'
    identities.mkdir(mode=0o700)
    policy = root / 'network'
    policy.mkdir(mode=0o755)
    # Gateway processes have no DAC override capability; only public policies are world-readable.
    root.chmod(0o755)
    subnet = f'172.29.{random.randint(128, 250)}.0/24'
    prefix = subnet.rsplit('.', 1)[0]
    addresses = dict(orca=prefix+'.2', executor=prefix+'.3')
    data = ('proxy_type=socks5\nproxy_address=192.0.2.20\nproxy_port=1080\n'
            'dns_address=1.1.1.1\ndns_transport=https\ndns_tls_name=cloudflare-dns.com\n'
            'executor_dns=\ncontrol_subnet='+subnet+'\nproxy_auth_file=\ninternal_ssh=yes\n')
    for name, content in [('policy.env',data),('executor-policy.env',data+'executor_mode=blocked\n'),('allow.tsv','')]:
        path=policy/name
        path.write_text(content)
        path.chmod(0o644)
    containers=[]
    network_created=False
    try:
        checked('network','create','--internal','--subnet',subnet,PREFIX)
        network_created=True
        checked('run','--rm','--network','none','--read-only','--tmpfs','/tmp','--user',f'{os.getuid()}:{os.getgid()}',
                '-e','HOME=/tmp','-v',str(identities)+':/identities',IMAGE,'python3','/opt/orca-setup/docker/ssh-identity.py',
                '/identities','fixture',addresses['orca'],addresses['executor'])
        fingerprints={role: (identities/role/'host.pub').read_bytes() for role in addresses}
        for role in addresses:
            gateway=PREFIX+'-'+role+'-gateway'
            containers.append(gateway)
            checked('run','-d','--name',gateway,'--network',PREFIX,'--ip',addresses[role],
                    '--sysctl','net.ipv6.conf.all.disable_ipv6=1','--sysctl','net.ipv6.conf.default.disable_ipv6=1',
                    '--cap-drop','ALL','--cap-add','NET_ADMIN','--cap-add','NET_BIND_SERVICE','--read-only','--tmpfs','/tmp',
                    '-v',str(policy)+':/etc/orca-network:ro','--entrypoint','/opt/orca-setup/docker/gateway.sh',IMAGE,role)
            eventually(lambda gateway=gateway: docker('exec',gateway,'/opt/orca-setup/docker/gateway.sh','check').returncode==0)
            home=root/(role+'-home')
            home.mkdir()
            name=PREFIX+'-'+role
            containers.append(name)
            checked('run','-d','--name',name,'--init','--network','container:'+gateway,'--user',f'{os.getuid()}:{os.getgid()}',
                    '--cap-drop','ALL','--security-opt','no-new-privileges:true','--read-only','--tmpfs','/tmp:exec,mode=1777',
                    '-e','HOME=/home/fixture','-e','USER=fixture','-e','ORCA_INTERNAL_SSH=yes',
                    '-v',str(home)+':/home/fixture','-v',str(identities/role)+':/run/orca-ssh:ro',
                    IMAGE,'python3','/opt/orca-setup/docker/orca-service.py','run','sleep','infinity')
        for role,peer in [('orca','executor'),('executor','orca')]:
            name=PREFIX+'-'+role
            eventually(lambda: docker('exec',name,'ssh','-o','ConnectTimeout=2',peer,'true').returncode==0)
            assert checked('exec',name,'ssh',peer,'id -u')==str(os.getuid())
            assert checked('exec',name,'ssh',peer,'echo $SHELL')=='/usr/bin/zsh'
            result=docker('exec',name,'ssh','-tt',peer,'zsh -ic \'[[ -n "$ZSH_VERSION" && -n "$ZSH" ]] && print OMZ_READY\'')
            assert result.returncode==0 and 'OMZ_READY' in result.stdout, result.stderr
            checked('exec',name,'bash','-c',"printf fixture > /tmp/scp-fixture; scp /tmp/scp-fixture "+peer+":scp-fixture; ssh "+peer+" test -f scp-fixture")
            # A remote SSH session survives stopping the application process manager's child.
            before=checked('inspect','--format','{{.Id}} {{.State.StartedAt}}',name)
            checked('exec',name,'python3','/opt/orca-setup/docker/orca-service.py','stop')
            checked('exec',PREFIX+'-'+peer,'ssh',role,'true')
            assert checked('inspect','--format','{{.Id}} {{.State.StartedAt}}',name)==before
            assert not json.loads(checked('inspect','--format','{{json .HostConfig.PortBindings}}',name))
            print(role+': SSH command, zsh/OMZ, PTY and application-stop survival passed',flush=True)
        # Executor still cannot connect directly to the public Internet.
        assert docker('exec',PREFIX+'-executor','python3','-c',
                      'import socket; socket.create_connection(("1.1.1.1",443),timeout=2)').returncode != 0
        # Recreating the server preserves the shell home and trusted host identity.
        checked('restart',PREFIX+'-orca')
        eventually(lambda: docker('exec',PREFIX+'-executor','ssh','-o','ConnectTimeout=2','orca','true').returncode==0)
        for role in addresses:
            assert (root/(role+'-home')/'.zshrc').is_file()
            assert fingerprints[role]==(identities/role/'host.pub').read_bytes()
        print('Pinned identities, persistent shell files, no host SSH publication and blocked executor egress passed',flush=True)
    except Exception:
        # Only fixture diagnostics, never production logs or generated key files.
        for name in containers:
            logs=docker('logs','--tail','8',name)
            print(name+': '+logs.stderr[-1500:],flush=True)
        raise
    finally:
        for name in reversed(containers):
            docker('rm','--force',name)
        if network_created:
            docker('network','rm',PREFIX)
