"""Management recovery and command boundaries, without a real account or deployment."""

import contextlib
import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("server_manage", ROOT / "lib/server-manage.py")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


def result(code=0, output=""):
    return subprocess.CompletedProcess([], code, stdout=output)


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "compose.yaml"
        self.path.write_text('# orca-setup: Orca server container for this user\nname: orca-server\nx-orca-setup:\n'
                             '  pairing-address: "server.example.com"\n  publish-address: "192.0.2.80"\n'
                             '  network-mode: "isolated"\n')
        self.state = {"installed": True, "error": "", "pairing-address": "server.example.com",
                      "services": {"orca-server": {"state": "running"}}}

    def test_status_is_read_only_and_scoped_to_this_deployment(self):
        with patch.object(manage, "docker", return_value=result(output="orca-server\trunning\tUp 1 hour\n")) as docker, \
                patch.object(manage.socket, "create_connection", side_effect=OSError):
            state = manage.snapshot(self.path)
        self.assertEqual(state["services"]["orca-server"]["state"], "running")
        self.assertIn("not reachable", state["port"])
        arguments = docker.call_args.args[0]
        self.assertEqual(arguments[0], "ps")
        self.assertIn("label=com.docker.compose.project.working_dir=" + str(self.path.parent), arguments)
        self.assertIn("label=com.docker.compose.oneoff=False", arguments)
        self.assertTrue(docker.call_args.kwargs["capture"])

    def test_docker_unavailable_does_not_claim_server_is_stopped(self):
        with patch.object(manage, "docker", return_value=result(125)):
            state = manage.snapshot(self.path)
        self.assertTrue(state["error"])
        self.assertEqual(state["port"], "not checked")

    def test_unrecognized_or_symlinked_compose_is_refused(self):
        other = self.path.parent / "link.yaml"
        other.symlink_to(self.path)
        with self.assertRaises(manage.ManagementError):
            manage.metadata(other)
        self.path.write_text("services: {}\n")
        with self.assertRaises(manage.ManagementError):
            manage.metadata(self.path)

    def test_pairing_on_legacy_manager_never_stops_anything(self):
        for mobile in (True, False):
            with patch.object(manage, "compose", return_value=result(output='{"state":"running"}')) as compose, \
                    patch.object(manage.subprocess, "Popen") as spawn:
                with self.assertRaisesRegex(manage.ManagementError, "No containers or Orca processes were stopped"):
                    manage.pair(self.path, mobile=mobile)
                compose.assert_called_once_with(self.path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", "status", capture=True)
                spawn.assert_not_called()

    def test_process_control_failure_never_falls_back_to_container_restart(self):
        with patch.object(manage, "compose_file", return_value=self.path), patch.object(manage.os, "getuid", return_value=os.getuid() or 1000), \
                patch.object(manage, "require_project_owner"), patch.object(manage, "compose", return_value=result(1)) as compose:
            for action in ("orca-start", "orca-stop", "orca-restart", "orca-status"):
                compose.reset_mock()
                with self.assertRaisesRegex(manage.ManagementError, "No containers were restarted"):
                    manage.main(action)
                compose.assert_called_once_with(self.path, "exec", "-T", "orca-server", "python3", "/opt/orca-service.py", action[5:])

    def test_start_keeps_installed_image_and_stops_preserve_volumes(self):
        with patch.object(manage, "compose_file", return_value=self.path), patch.object(manage.os, "getuid", return_value=os.getuid() or 1000), \
                patch.object(manage, "require_project_owner"), patch.object(manage, "compose", return_value=result()) as compose:
            manage.main("start")
            self.assertEqual(compose.call_args.args, (self.path, "up", "--detach", "--no-recreate", "--pull", "never"))
            manage.main("stop")
            self.assertEqual(compose.call_args.args, (self.path, "stop"))

    def test_unique_project_is_used_for_status_and_compose_despite_environment_override(self):
        self.path.write_text(self.path.read_text().replace("name: orca-server", "name: orca-1000-abcdef123456"))
        with patch.dict(os.environ, {"COMPOSE_PROJECT_NAME": "unrelated"}), \
                patch.object(manage, "docker", return_value=result()) as docker, \
                patch.object(manage.socket, "create_connection", side_effect=OSError):
            state = manage.snapshot(self.path)
            self.assertEqual(state["project"], "orca-1000-abcdef123456")
            self.assertIn("label=com.docker.compose.project=orca-1000-abcdef123456", docker.call_args.args[0])
            manage.compose(self.path, "stop")
            self.assertEqual(docker.call_args.args[0][:3], ["compose", "--project-name", "orca-1000-abcdef123456"])

    def test_uninstall_archives_compose_and_preserves_user_files(self):
        settings = self.path.parent / "server.toml"
        settings.write_text("fixture settings")
        before = self.path.read_bytes()
        with patch.object(manage, "compose", return_value=result()) as compose, contextlib.redirect_stdout(io.StringIO()):
            manage.uninstall(self.path)
        compose.assert_called_once_with(self.path, "down", "--remove-orphans")
        self.assertFalse(self.path.exists())
        self.assertEqual(self.path.with_name("compose.uninstalled.yaml").read_bytes(), before)
        self.assertEqual(settings.read_text(), "fixture settings")
        self.assertFalse(manage.snapshot(self.path)["installed"])

    def test_failed_uninstall_keeps_installed_state(self):
        with patch.object(manage, "compose", return_value=result(1)), self.assertRaises(manage.ManagementError):
            manage.uninstall(self.path)
        self.assertTrue(self.path.exists())
        self.assertFalse(self.path.with_name("compose.uninstalled.yaml").exists())

    def test_management_refuses_project_owned_by_another_directory(self):
        with patch.object(manage, "compose_file", return_value=self.path), \
                patch.object(manage.os, "getuid", return_value=os.getuid() or 1000), \
                patch.object(manage, "docker", return_value=result(output="/another/installation\n")), \
                patch.object(manage, "compose") as compose, self.assertRaises(manage.ManagementError):
            manage.main("uninstall")
        compose.assert_not_called()

    def test_concurrent_management_is_refused(self):
        with manage.deployment_lock(self.path), self.assertRaises(manage.ManagementError), manage.deployment_lock(self.path):
            self.fail("a second management operation acquired the lock")


if __name__ == "__main__":
    unittest.main()
