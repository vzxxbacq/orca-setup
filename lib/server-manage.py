"""Manage the generated deployment without reading account state or capturing pairing output."""

import contextlib
import fcntl
import ipaddress
import json
import os
import re
import select
import signal
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SERVICES = ("orca-server", "orca-gateway", "executor-gateway", "orca-executor")
DOCKER_SCRIPT = '''set -euo pipefail
. "$1/lib/common.sh"
. "$1/lib/docker-host.sh"
. "$1/modules/containers.sh"
shift
require_non_root
docker_connect || exit 125
dk "$@"
'''
MAINTENANCE_PAIRING_NOTICE = (
    "Maintenance pairing briefly stops Orca and starts its pairing mode inside the same container. "
    "Docker, gateways and independent workers remain running; Orca connections and Orca-owned sessions may be interrupted.\n\n"
    "The QR code or link appears in this terminal only. After pairing, press Enter to confirm exit and restore normal Orca; Ctrl-C also exits. "
    "If the terminal disconnects, the manager restores service after the lease expires. "
    "Older deployments require Apply during a maintenance window."
)


class ManagementError(ValueError):
    pass


def compose_file():
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config").expanduser() / "orca-setup/docker/compose.yaml"


def metadata(path):
    if path.is_symlink():
        raise ManagementError("Generated Compose must not be a symbolic link.")
    info = path.stat()
    if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
        raise ManagementError("Generated Compose must be a regular file owned by this user.")
    text = path.read_text()
    if not text.startswith("# orca-setup: Orca server container for this user\n"):
        raise ManagementError("This Compose file is not an orca-setup deployment.")
    project = re.search(r'^name: ([a-z0-9][a-z0-9_-]*)$', text, re.MULTILINE)
    if project is None:
        raise ManagementError("The generated Compose project name is missing or invalid.")
    return {"project": project.group(1), **{key: value for key, value in re.findall(
        r'^  (pairing-address|publish-address|network-mode|process-manager): "([^"\n]*)"$', text, re.MULTILINE)}}


def docker(arguments, capture=False, timeout=None):
    return subprocess.run(["bash", "-c", DOCKER_SCRIPT, "orca-docker", str(ROOT), *arguments],
                          check=False, timeout=timeout, text=True,
                          stdin=subprocess.DEVNULL if capture else None,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.DEVNULL if capture else None)


def compose(path, *arguments, capture=False):
    return docker(["compose", "--project-name", metadata(path)["project"],
                   "--project-directory", str(path.parent), "-f", str(path), *arguments], capture=capture,
                  timeout=15 if capture else None)


def snapshot(path=None):
    path = path or compose_file()
    result = {"installed": path.is_file(), "compose": str(path), "services": {}, "error": "", "port": "not checked"}
    if not result["installed"]:
        return result
    try:
        result.update(metadata(path))
        query = docker(["ps", "--all", "--filter", "label=com.docker.compose.project=" + result["project"],
                        "--filter", "label=com.docker.compose.project.working_dir=" + str(path.parent),
                        "--filter", "label=com.docker.compose.oneoff=False",
                        "--format", '{{.Label "com.docker.compose.service"}}\t{{.State}}\t{{.Status}}'],
                       capture=True, timeout=10)
        if query.returncode:
            result["error"] = "Docker is unavailable to this user. Check Docker and group access."
            return result
        for line in query.stdout.splitlines():
            values = line.split("\t", 2)
            if len(values) == 3 and values[0] in SERVICES:
                result["services"][values[0]] = {"state": values[1], "status": values[2]}
        if "process-manager" in result and result["services"].get("orca-server", {}).get("state") == "running":
            probe = compose(path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", "status", capture=True)
            try:
                process = json.loads(probe.stdout) if not probe.returncode else {}
                result["orca-process"] = process.get("state", "unavailable")
            except (ValueError, AttributeError):
                result["orca-process"] = "unavailable"
        host = result.get("publish-address", "")
        ipaddress.IPv4Address(host)
        try:
            with socket.create_connection((host, 6768), timeout=1):
                result["port"] = "reachable from this host (TCP)"
        except OSError:
            result["port"] = "not reachable from this host"
    except (OSError, ValueError, subprocess.TimeoutExpired):
        result["error"] = "Cannot inspect this deployment. Check the generated Compose and Docker."
    return result


def require_success(result, message):
    if result.returncode:
        raise ManagementError(message)


def require_project_owner(path):
    """Compose mutations must not touch a legacy project created by another install."""
    project = metadata(path)["project"]
    query = docker(["ps", "--all", "--filter", "label=com.docker.compose.project=" + project,
                    "--format", '{{.Label "com.docker.compose.project.working_dir"}}'], capture=True, timeout=10)
    require_success(query, "Cannot verify deployment ownership; no containers were changed.")
    if any(Path(line).resolve() != path.parent.resolve() for line in query.stdout.splitlines()):
        raise ManagementError("This Docker project belongs to another installation directory; no containers were changed.")


def uninstall(path):
    # No --volumes or --rmi: user files, private auth volumes and images survive.
    archive = path.with_name("compose.uninstalled.yaml")
    if archive.is_symlink() or (archive.exists() and (not archive.is_file() or archive.stat().st_uid != os.getuid())):
        raise ManagementError("Cannot archive the deployment; check compose.uninstalled.yaml ownership.")
    require_success(compose(path, "down", "--remove-orphans"), "Uninstall did not complete. Configuration was retained; retry after Docker recovers.")
    path.replace(archive)
    print("Server uninstalled. Configuration, backups, images, volumes and user files were retained.", flush=True)
    print("Previous deployment: " + str(archive), flush=True)


def pair(path, mobile=False):
    """The container manager owns recovery; the host supplies a short-lived stdin lease."""
    probe = compose(path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", "status", capture=True)
    try:
        supported = probe.returncode == 0 and json.loads(probe.stdout).get("maintenance_pairing") == 1
    except (ValueError, AttributeError):
        supported = False
    if not supported:
        raise ManagementError("Maintenance pairing requires the updated process manager. Apply during a maintenance window first. No containers or Orca processes were stopped.")
    print("Scan the mobile QR code below." if mobile else "On your Mac: Settings > Remote Orca Servers > Add Server. Copy the link below.", flush=True)
    print("After pairing, press Enter for the exit confirmation. Ctrl-C also restores Orca. Do not save terminal output.", flush=True)
    arguments = ["compose", "--project-name", metadata(path)["project"], "--project-directory", str(path.parent),
                 "-f", str(path), "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", "pair-mobile" if mobile else "pair"]
    process = subprocess.Popen(["bash", "-c", DOCKER_SCRIPT, "orca-docker", str(ROOT), *arguments], stdin=subprocess.PIPE,
                               start_new_session=True)
    interrupted = False
    confirming_exit = False
    interactive = sys.stdin.isatty()
    typed = b""
    try:
        while process.poll() is None:
            try:
                process.stdin.write(b'.')
                process.stdin.flush()
            except BrokenPipeError:
                break
            if interactive:
                ready, _, _ = select.select([sys.stdin], [], [], 1)
                if ready:
                    incoming = os.read(sys.stdin.fileno(), 1024)
                    if not incoming:
                        interrupted = True
                        break
                    typed += incoming
                    while b"\n" in typed:
                        line, typed = typed.split(b"\n", 1)
                        if confirming_exit:
                            if line.strip().lower() in (b"y", b"yes"):
                                interrupted = True
                                print("Restoring normal Orca...", flush=True)
                                break
                            confirming_exit = False
                            print("Pairing continues. Press Enter when finished.", flush=True)
                        else:
                            confirming_exit = True
                            print("\n\033[1;36mExit pairing and restore normal Orca?\033[0m [y/N] ", end="", flush=True)
                    if interrupted:
                        break
            else:
                time.sleep(1)
    except KeyboardInterrupt:
        interrupted = True
    finally:
        try:
            process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            process.wait(timeout=80)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)
        # No offer is captured: only the public service status is read after lease release.
        deadline = time.monotonic() + 80
        while time.monotonic() < deadline:
            try:
                restored = compose(path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", "status", capture=True)
                if restored.returncode == 0:
                    state = json.loads(restored.stdout)
                    print("Pairing ended. Orca process: " + state.get("state", "unknown") + ". Containers were not restarted.", flush=True)
                    break
            except (subprocess.TimeoutExpired, ValueError):
                pass
            time.sleep(1)
        else:
            raise ManagementError("Pairing ended but recovery could not be verified. Check Orca process status; do not restart the deployment automatically.")

    if state.get("state") != json.loads(probe.stdout).get("state"):
        raise ManagementError("Orca did not return to its previous process state. Check service status before retrying.")
    if not interrupted and process.returncode:
        raise ManagementError("Pairing command failed. Previous Orca process state was restored; no containers were restarted.")


@contextlib.contextmanager
def deployment_lock(path):
    descriptor = os.open(path.parent / "manage.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ManagementError("Another management operation is in progress.") from None
        yield
    finally:
        os.close(descriptor)


def main(action):
    if os.getuid() == 0:
        raise ManagementError("Run as your regular user, without sudo.")
    if action not in ("start", "stop", "restart", "pair", "pair-mobile", "uninstall", "orca-start", "orca-stop", "orca-restart", "orca-status"):
        raise ManagementError("Unknown management action.")
    path = compose_file()
    metadata(path)
    with deployment_lock(path):
        require_project_owner(path)
        if action in ("pair", "pair-mobile"):
            pair(path, mobile=action == "pair-mobile")
        elif action.startswith("orca-"):
            require_success(compose(path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", action[5:]),
                            "Orca process control failed. No containers were restarted. Older deployments require Apply during a maintenance window.")
        elif action == "uninstall":
            uninstall(path)
        elif action == "start":
            require_success(compose(path, "up", "--detach", "--no-recreate", "--pull", "never"), "Could not start the installed deployment.")
        elif action == "stop":
            require_success(compose(path, "stop"), "Could not stop the installed deployment.")
        else:
            # Starting the full stack preserves namespace dependency ordering.
            require_success(compose(path, "stop"), "Could not stop the installed deployment.")
            require_success(compose(path, "up", "--detach", "--no-recreate", "--pull", "never"), "Could not restart the installed deployment.")


if __name__ == "__main__":
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    for termination in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(termination, interrupted)
    try:
        if len(sys.argv) != 2:
            raise ManagementError("Choose a management action from the TUI.")
        main(sys.argv[1])
    except KeyboardInterrupt:
        print("\nOperation interrupted.", file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print("ERROR: " + (str(error) if isinstance(error, ManagementError) else "Management action failed; check Docker and deployment files."), file=sys.stderr)
        sys.exit(1)
