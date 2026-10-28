"""Real Docker lifecycle tests with a fake CLI; no accounts or pairing offers are created.

Run as a regular Docker user with ORCA_SETUP_TEST_IMAGE naming an already available server image.
Only temporary fixture containers and a loopback port are used; the real deployment is untouched.
"""

import importlib.util
import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("server_manage", ROOT / "lib/server-manage.py")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)

FAKE_CLI = '''#!/usr/bin/python3
import http.server
import signal
import sys
signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
if '--no-pairing' not in sys.argv:
    from pathlib import Path
    if Path('/fixture/fail-pair').exists():
        raise SystemExit(7)
    print('[agent-state-rules] download failed: HTTP 404', flush=True)
    print('FIXTURE MOBILE QR' if '--mobile-pairing' in sys.argv else 'FIXTURE CLIENT LINK', flush=True)
server = http.server.HTTPServer(('0.0.0.0', 6768), http.server.SimpleHTTPRequestHandler)
server.serve_forever()
'''


def eventually(check, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.2)
    raise AssertionError("Fixture did not reach the expected state")


def verify(mode, image):
    with tempfile.TemporaryDirectory(prefix="orca-tui-test-") as temporary:
        root = Path(temporary)
        config_root = root / "config"
        compose_dir = config_root / "orca-setup/docker"
        compose_dir.mkdir(parents=True)
        path = compose_dir / "compose.yaml"
        fixture = root / "fixture"
        fixture.mkdir()
        cli = fixture / "fake-cli"
        cli.write_text(FAKE_CLI)
        cli.chmod(0o755)
        name = "orca-tui-fixture-" + root.name.removeprefix("orca-tui-test-")
        server = {"image": image, "pull_policy": "never", "container_name": name,
                  "user": f"{os.getuid()}:{os.getgid()}", "environment": {"ORCA_CLI_COMMAND": "/fixture/fake-cli"},
                  "volumes": [str(fixture) + ":/fixture", str(ROOT / "docker/orca-service.py") + ":/opt/orca-service.py:ro"],
                  "init": True, "command": ["python3", "/opt/orca-service.py", "run", "/fixture/fake-cli", "serve", "--no-pairing"],
                  "ports": ["127.0.0.2:6768:6768"],
                  "logging": {"driver": "json-file", "options": {"max-size": "1m", "max-file": "1"}}}
        services = {"orca-server": server}
        if mode == "isolated":
            services["orca-gateway"] = {"image": image, "pull_policy": "never", "container_name": name + "-gateway",
                                        "command": ["sleep", "infinity"],
                                        "ports": server.pop("ports")}
            server["network_mode"] = "service:orca-gateway"
            server["depends_on"] = ["orca-gateway"]
        # JSON is valid YAML; metadata mirrors the real generated file's fixed public header.
        path.write_text('# orca-setup: Orca server container for this user\n'
                        'x-orca-setup:\n  pairing-address: "fixture.example.com"\n'
                        '  publish-address: "127.0.0.2"\n  network-mode: "' + mode + '"\n'
                        'name: ' + name + '\nservices: ' + json.dumps(services) + '\n')
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(config_root)}):
            try:
                manage.main("start")
                eventually(lambda: manage.snapshot()["port"].startswith("reachable"))
                before_gateway = manage.docker(["inspect", "--format", "{{.State.StartedAt}}", name + "-gateway"], capture=True).stdout if mode == "isolated" else ""
                # An independent long-running process stands in for an active agent.
                worker = ("from pathlib import Path\nimport time\np=Path('/fixture/heartbeat')\n"
                          "while True:\n p.write_text(str(time.monotonic_ns()))\n time.sleep(0.1)\n")
                started = manage.docker(["exec", "--detach", name, "python3", "-c", worker])
                assert started.returncode == 0
                eventually(lambda: (fixture / "heartbeat").exists())
                before = manage.docker(["inspect", "--format", "{{.Id}} {{.State.StartedAt}}", name], capture=True).stdout
                for action in ("orca-stop", "orca-start", "orca-restart"):
                    heartbeat = (fixture / "heartbeat").read_text()
                    manage.main(action)
                    if action == "orca-stop":
                        probe = manage.compose(path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", "status", capture=True)
                        assert probe.returncode == 0 and json.loads(probe.stdout)["state"] == "stopped"
                    else:
                        eventually(lambda: manage.snapshot()["port"].startswith("reachable"))
                    after = manage.docker(["inspect", "--format", "{{.Id}} {{.State.StartedAt}}", name], capture=True).stdout
                    assert before == after, "Process control restarted the container"
                    eventually(lambda: (fixture / "heartbeat").read_text() not in ("", heartbeat))
                for action, abort in (("pair", signal.SIGINT), ("pair-mobile", signal.SIGINT), ("pair-mobile", signal.SIGKILL), ("pair-mobile", "enter")):
                    heartbeat = (fixture / "heartbeat").read_text()
                    master, slave = pty.openpty() if abort == "enter" else (None, None)
                    process = subprocess.Popen([sys.executable, str(ROOT / "lib/server-manage.py"), action],
                                               stdin=slave if slave is not None else subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                    output = b""
                    marker = b"FIXTURE MOBILE QR" if action == "pair-mobile" else b"FIXTURE CLIENT LINK"
                    try:
                        deadline = time.monotonic() + 30
                        while marker not in output and time.monotonic() < deadline:
                            ready, _, _ = select.select([process.stdout], [], [], 1)
                            if ready:
                                chunk = os.read(process.stdout.fileno(), 8192)
                                if not chunk:
                                    break
                                output += chunk
                        assert marker in output, "Fixture pairing offer was not streamed: " + output.decode()
                        assert b"Optional upstream rules are unavailable" in output
                        if abort == "enter":
                            os.write(master,b"\n")
                            deadline=time.monotonic()+10
                            while b"[y/N]" not in output and time.monotonic()<deadline:
                                ready,_,_=select.select([process.stdout],[],[],1)
                                if ready: output+=os.read(process.stdout.fileno(),8192)
                            assert b"[y/N]" in output
                            # Confirmation must not starve the manager's 10-second lease.
                            time.sleep(11)
                            assert process.poll() is None
                            os.write(master,b"n\n")
                            deadline=time.monotonic()+10
                            while b"Pairing continues" not in output and time.monotonic()<deadline:
                                ready,_,_=select.select([process.stdout],[],[],1)
                                if ready: output+=os.read(process.stdout.fileno(),8192)
                            assert b"Pairing continues" in output
                            os.write(master,b"\ny\n")
                        else:
                            process.send_signal(abort)
                        remainder, _ = process.communicate(timeout=90)
                        output += remainder
                        if abort in (signal.SIGINT, "enter"):
                            assert process.returncode == 0, output.decode()
                            assert b"Containers were not restarted" in output
                        def restored():
                            query = manage.compose(path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", "status", capture=True)
                            return query.returncode == 0 and json.loads(query.stdout)["state"] == "running"
                        eventually(restored)
                    finally:
                        if master is not None:
                            os.close(master)
                            os.close(slave)
                        if process.poll() is None:
                            process.kill()
                            process.communicate(timeout=90)
                    after = manage.docker(["inspect", "--format", "{{.Id}} {{.State.StartedAt}}", name], capture=True).stdout
                    assert before == after, "Pairing restarted or replaced the container"
                    eventually(lambda: (fixture / "heartbeat").read_text() not in ("", heartbeat))
                    logs = manage.docker(["logs", name], capture=True).stdout
                    assert "FIXTURE MOBILE QR" not in logs and "FIXTURE CLIENT LINK" not in logs, "Offer leaked into container logs"
                (fixture / "fail-pair").touch()
                failed = subprocess.run([sys.executable, str(ROOT / "lib/server-manage.py"), "pair-mobile"],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=90)
                assert failed.returncode == 1 and "Previous Orca process state was restored" in failed.stdout, failed.stdout
                (fixture / "fail-pair").unlink()
                after = manage.docker(["inspect", "--format", "{{.Id}} {{.State.StartedAt}}", name], capture=True).stdout
                assert before == after
                if mode == "isolated":
                    after_gateway = manage.docker(["inspect", "--format", "{{.State.StartedAt}}", name + "-gateway"], capture=True).stdout
                    assert before_gateway == after_gateway, "Pairing restarted the gateway"
                manage.main("stop")
                assert manage.snapshot()["services"]["orca-server"]["state"] == "exited"
                manage.main("start")
                eventually(lambda: manage.snapshot()["port"].startswith("reachable"))
                manage.main("restart")
                eventually(lambda: manage.snapshot()["port"].startswith("reachable"))
                (fixture / "keep.txt").write_text("persistent fixture data")
                compose_before = path.read_bytes()
                manage.main("uninstall")
                assert not path.exists()
                assert path.with_name("compose.uninstalled.yaml").read_bytes() == compose_before
                assert (fixture / "keep.txt").read_text() == "persistent fixture data"
                assert not manage.snapshot()["installed"]
                query = manage.docker(["ps", "--all", "--quiet", "--filter", "label=com.docker.compose.project=" + name], capture=True)
                assert not query.stdout.strip(), "Uninstall left fixture containers"
                networks = manage.docker(["network", "ls", "--quiet", "--filter", "label=com.docker.compose.project=" + name], capture=True)
                assert not networks.stdout.strip(), "Uninstall left fixture networks"
                path.write_bytes(compose_before)
                manage.main("start")
                eventually(lambda: manage.snapshot()["port"].startswith("reachable"))
                assert (fixture / "keep.txt").read_text() == "persistent fixture data"
                manage.main("uninstall")
                print(mode + ": lifecycle, maintenance pairing, crash recovery and an uninterrupted worker, uninstall, retained data and reinstall passed", flush=True)
            finally:
                # Only fixture containers with this unique working-directory label are removed.
                query = manage.docker(["ps", "--all", "--quiet", "--filter",
                                       "label=com.docker.compose.project.working_dir=" + str(compose_dir)], capture=True)
                if query.stdout.strip():
                    manage.docker(["rm", "--force", *query.stdout.split()])
                networks = manage.docker(["network", "ls", "--quiet", "--filter", "label=com.docker.compose.project=" + name], capture=True)
                if networks.stdout.strip():
                    manage.docker(["network", "rm", *networks.stdout.split()])


if __name__ == "__main__":
    if os.getuid() == 0:
        raise SystemExit("Run as a regular Docker user.")
    image = os.environ["ORCA_SETUP_TEST_IMAGE"]
    for mode in ("direct", "isolated"):
        verify(mode, image)
