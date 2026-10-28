"""Exercise native Orca in a disposable container with no host profile or published port."""
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

if os.getuid() == 0:
    raise SystemExit('Run as a regular Docker user.')

ROOT = Path(__file__).resolve().parents[2]
name = 'orca-service-native-test-' + uuid.uuid4().hex[:12]
image = os.environ['ORCA_SETUP_TEST_IMAGE']


def docker(*args):
    return subprocess.run(['docker', *args], capture_output=True, text=True, timeout=90)


def runtime_up():
    code = 'import socket; s=socket.create_connection(("127.0.0.1",6768),timeout=1); s.close()'
    return docker('exec', name, 'python3', '-c', code).returncode == 0


def wait_runtime():
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if runtime_up():
            return
        time.sleep(1)
    raise AssertionError('Native fixture did not become ready; logs intentionally not printed.')


try:
    started = docker('run', '--detach', '--name', name, '--init', '--read-only',
                     '--tmpfs', '/tmp:exec,mode=1777', '--user', f'{os.getuid()}:{os.getgid()}',
                     '--env', 'HOME=/tmp/native-fixture-home', '--env', 'USER=fixture',
                     '--mount', f'type=bind,src={ROOT / "docker/orca-service.py"},dst=/opt/orca-service.py,readonly',
                     image, 'bash', '-c', 'mkdir -p "$HOME"; . /opt/orca-setup/lib/detect.sh; cli=$(detect_orca_cli); exec python3 /opt/orca-service.py run "$cli" serve --supervise --no-pairing --port 6768')
    assert started.returncode == 0, 'Could not start native fixture.'
    wait_runtime()
    before = docker('inspect', '--format', '{{.Id}} {{.State.StartedAt}}', name).stdout
    worker = docker('exec', '--detach', name, 'bash', '-c', 'while :; do date +%s%N > /tmp/worker-heartbeat; sleep 0.1; done')
    assert worker.returncode == 0
    heartbeat = docker('exec', name, 'cat', '/tmp/worker-heartbeat').stdout
    stopped = docker('exec', name, 'python3', '/opt/orca-service.py', 'stop')
    assert stopped.returncode == 0 and json.loads(stopped.stdout)['state'] == 'stopped'
    assert not runtime_up(), 'Native runtime remained listening after CLI stop.'
    time.sleep(.3)
    assert heartbeat != docker('exec', name, 'cat', '/tmp/worker-heartbeat').stdout
    assert docker('exec', name, 'python3', '/opt/orca-service.py', 'start').returncode == 0
    wait_runtime()
    assert before == docker('inspect', '--format', '{{.Id}} {{.State.StartedAt}}', name).stdout
    print('Native Orca stop/start passed; container identity and independent worker survived. Orca-owned agents were not tested.')
finally:
    docker('rm', '--force', name)
