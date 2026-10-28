"""Exercise terminal configuration without Docker or real credentials."""

import contextlib
import copy
import fcntl
import importlib.util
import io
import os
import pty
import select
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tomllib
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("server_tui", ROOT / "lib/server-tui.py")
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)


class ServerTuiTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name).resolve() / "server.toml"
        deployment = patch.object(tui.manager, "compose_file", return_value=self.path.parent / "compose.yaml")
        deployment.start()
        self.addCleanup(deployment.stop)
        self.data = {
            "server": {"role": "server", "home_mount": "host", "pairing_address": "server.example.com",
                       "publish_address": "203.0.113.10", "workdir": "./work"},
            "network": {"mode": "isolated"},
            "proxy": {"type": "socks5", "address": "192.0.2.20", "port": 1080,
                      "username": "fixture", "password": "FAKE-SECRET-SENTINEL"},
            "executor": {"internet": "proxy", "proxy": {"address": "192.0.2.21", "port": 1081,
                                                          "username": "second", "password": "FAKE-SECOND-SECRET"},
                         "allow": [{"name": "git", "cidr": "172.20.1.0/24", "port": 443}]},
            "limits": {"mem_limit": "8g", "cpus": 2.5},
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_save_round_trips_tables_with_private_permissions(self):
        tui.save(self.path, self.data)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(tomllib.loads(self.path.read_text()), self.data)
        public, _ = tui.server_config.load(self.path)
        self.assertEqual(public["executor_internet"], "proxy")
        self.assertNotIn("FAKE-SECRET-SENTINEL", repr(public))
        self.assertNotIn("FAKE-SECOND-SECRET", repr(public))

    def test_invalid_change_does_not_replace_existing_configuration(self):
        tui.save(self.path, self.data)
        before = self.path.read_bytes()
        self.data["executor"]["internet"] = "invalid"
        with self.assertRaises(ValueError):
            tui.save(self.path, self.data)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in self.path.parent.iterdir()), ["server.toml"])

    def test_inline_configuration_in_shared_workdir_is_not_written(self):
        self.data["server"]["workdir"] = str(self.path.parent)
        with self.assertRaises(ValueError):
            tui.save(self.path, self.data)
        self.assertFalse(self.path.exists())

    def test_authentication_prompt_does_not_echo_password(self):
        output = io.StringIO()
        proxy = {"address": "192.0.2.20"}
        with patch.object(tui, "ask", side_effect=["inline", "fixture"]), \
             patch.object(tui.getpass, "getpass", return_value="FAKE-SECRET-SENTINEL"), \
             contextlib.redirect_stdout(output):
            tui.auth_settings(proxy)
        self.assertEqual(proxy["password"], "FAKE-SECRET-SENTINEL")
        self.assertNotIn("FAKE-SECRET-SENTINEL", output.getvalue())

    def test_storage_summary_explains_persistent_and_temporary_paths_without_secrets(self):
        output = io.StringIO()
        cfg = str(self.path.parent / "config")
        state = str(self.path.parent / "state")
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": cfg, "XDG_DATA_HOME": state}), contextlib.redirect_stdout(output):
            tui.storage_summary(self.path, self.data)
        text = output.getvalue()
        for item in (str(self.path), cfg + "/orca-setup/docker/compose.yaml", cfg + "/orca-setup/docker/network",
                     state + "/orca-setup/executor-home", str(self.path.parent / "work"), str(Path.home()), "/tmp"):
            self.assertIn(item, text)
        self.assertNotIn("FAKE-SECRET-SENTINEL", text)
        self.assertNotIn("FAKE-SECOND-SECRET", text)

    @contextlib.contextmanager
    def terminal(self, command=None, rows=30, columns=100, color=True):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        original = termios.tcgetattr(slave)
        environment = {**os.environ, "TERM": "xterm-256color",
                       "XDG_CONFIG_HOME": str(self.path.parent / "config"),
                       "XDG_DATA_HOME": str(self.path.parent / "state")}
        environment.pop("NO_COLOR", None)
        if not color:
            environment["NO_COLOR"] = "1"
        process = subprocess.Popen(command or [sys.executable, str(ROOT / "lib/server-tui.py"), str(self.path)],
                                   stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=environment)
        try:
            yield master, process
            # macOS waits for the PTY output queue to drain when curses restores termios.
            deadline = time.monotonic() + 5
            while process.poll() is None and time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    os.read(master, 65536)
            process.wait(timeout=5)
            self.assertEqual(process.returncode, 0)
            restored = termios.tcgetattr(slave)
            # Ignore kernel-owned flags such as macOS PENDIN.
            flags = termios.ECHO | termios.ICANON | termios.ISIG
            self.assertEqual(restored[3] & flags, original[3] & flags)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)

    def read_until(self, master, marker):
        output = b""
        deadline = time.monotonic() + 5
        while marker not in output and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    output += os.read(master, 65536)
                except OSError:
                    break
        self.assertIn(marker, output)
        return output

    def test_quit_in_terminal_is_read_only(self):
        with self.terminal() as (master, _):
            output = self.read_until(master, b"Esc")
            os.write(master, b"0\n")
        self.assertFalse(self.path.exists())
        self.assertIn(b"Linux Server Setup", output)
        self.assertIn(b"Server & storage", output)
        self.assertIn(b"36m", output)  # Cyan accents on a color terminal.

    def test_arrow_navigation_and_cancel_do_not_write(self):
        tui.save(self.path, self.data)
        original = self.path.read_bytes()
        with self.terminal() as (master, _):
            output = self.read_until(master, b"Esc")
            os.write(master, b"\n")  # The first section is already selected.
            output += self.read_until(master, b"Address clients use")
            os.write(master, b"\x15changed.example.com\n")
            output += self.read_until(master, b"Private IPv4 address on this host")
            os.write(master, b"\x1b")
            output += self.read_until(master, b"INSTALL / CONFIGURATION")
            os.write(master, b"0\n")
        self.assertEqual(original, self.path.read_bytes())
        self.assertNotIn(b"FAKE-SECRET-SENTINEL", output)
        self.assertNotIn(b"FAKE-SECOND-SECRET", output)

    def test_password_is_masked_and_terminal_is_restored(self):
        command = [sys.executable, "-c", f"""
import curses, importlib.util
spec = importlib.util.spec_from_file_location('screen', {str(ROOT / 'lib/server-tui-screen.py')!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def run(window):
    value = module.Screen(window, 'fixture.toml').prompt('Password', secret=True)
    assert value == 'FAKE-SECRET-SENTINEL'
curses.wrapper(run)
"""]
        with self.terminal(command) as (master, _):
            output = self.read_until(master, b"Ctrl-U")
            os.write(master, b"FAKE-SECRET-SENTINEL")
            output += self.read_until(master, b"*")
            os.write(master, b"\n")
        self.assertNotIn(b"FAKE-SECRET-SENTINEL", output)

    def test_small_monochrome_terminal_can_resize_and_quit(self):
        with self.terminal(rows=15, columns=50, color=False) as (master, process):
            self.read_until(master, b"Enlarge")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            process.send_signal(signal.SIGWINCH)
            os.write(master, b"x")
            output = self.read_until(master, b"Server & storage")
            self.assertIn(b"Server & storage", output)
            self.assertNotIn(b"36m", output)
            os.write(master, b"0\n")
        self.assertFalse(self.path.exists())

    def test_cancelled_form_rolls_back_all_partial_edits(self):
        data = copy.deepcopy(self.data)
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["server", "quit"]
        def cancel(draft):
            draft["server"]["publish_address"] = "192.0.2.80"
            raise tui.screen.Cancelled
        with patch.object(tui.screen, "Screen", return_value=ui), patch.object(tui, "server_settings", side_effect=cancel):
            tui.session(None, self.path, data)
        self.assertEqual(data, self.data)
        self.assertFalse(self.path.exists())
        ui.run.assert_not_called()

    def test_install_saves_only_after_confirmation_and_before_start(self):
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["apply", "apply", "quit"]
        ui.confirm.side_effect = [False, True]
        def run(command):
            self.assertEqual(tomllib.loads(self.path.read_text()), self.data)
            self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
            self.assertEqual(command, [str(ROOT / "setup.sh"), "--config", str(self.path), "--apply"])
            return 1
        ui.run.side_effect = run
        with patch.object(tui.screen, "Screen", return_value=ui):
            tui.session(None, self.path, copy.deepcopy(self.data))
        ui.run.assert_called_once()
        self.assertEqual(ui.confirm.call_count, 2)
        review = ui.confirm.call_args.args[1]
        for value in ("203.0.113.10:6768", "192.0.2.20:1080", "Memory: 8g", str(self.path), "Configuration backups"):
            self.assertIn(value, review)
        self.assertNotIn("FAKE-SECRET-SENTINEL", review)
        self.assertNotIn("FAKE-SECOND-SECRET", review)

    def test_review_buttons_are_on_same_screen_and_default_to_no(self):
        for keys, accepted in ((b"\n", False), (b"\t\n", True), (b"\x1b", False)):
            with self.subTest(keys=keys):
                command = [sys.executable, "-c", f"""
import curses, importlib.util
spec = importlib.util.spec_from_file_location('screen', {str(ROOT / 'lib/server-tui-screen.py')!r})
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
def run(window):
    text = '\\n'.join('Review line %02d' % index for index in range(50))
    return module.Screen(window, 'fixture.toml').confirm('Install this server?', text)
assert curses.wrapper(run) is {accepted!r}
"""]
                with self.terminal(command, rows=20, columns=64) as (master, process):
                    output = self.read_until(master, b"Confirm")
                    for marker in (b"Review line 00", b"Yes, install", b"No, go back"):
                        self.assertIn(marker, output)
                    os.write(master, b"\x1b[6~")
                    self.read_until(master, b"6-10/50")
                    self.assertIsNone(process.poll())
                    os.write(master, keys)

    def test_cancelling_install_does_not_save_or_back_up(self):
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["apply", "quit"]
        ui.confirm.return_value = False
        with patch.object(tui.screen, "Screen", return_value=ui):
            tui.session(None, self.path, copy.deepcopy(self.data))
        self.assertFalse(self.path.exists())
        self.assertFalse(tui.backup_directory(self.path).exists())
        ui.run.assert_not_called()

    def test_auto_backup_preserves_exact_old_bytes_and_can_be_restored(self):
        tui.save(self.path, self.data)
        original = b"# Preserve the original comment\n" + self.path.read_bytes()
        self.path.write_bytes(original)
        changed = copy.deepcopy(self.data)
        changed["server"]["publish_address"] = "192.0.2.80"
        backup = tui.save(self.path, changed)
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(backup.parent.stat().st_mode), 0o700)
        self.assertIsNone(tui.save(self.path, changed))
        self.assertEqual(tui.list_backups(self.path), [backup])
        restored = tui.load_backup(self.path, backup)
        self.assertEqual(restored, self.data)
        self.assertEqual(restored["server"]["workdir"], "./work")
        current = self.path.read_bytes()
        before_restore = tui.save(self.path, restored)
        self.assertEqual(before_restore.read_bytes(), current)
        self.assertEqual(tomllib.loads(self.path.read_text()), self.data)
        self.assertEqual(len(tui.list_backups(self.path)), 2)

    def test_restore_loads_draft_without_writing_or_deploying(self):
        tui.save(self.path, self.data)
        changed = copy.deepcopy(self.data)
        changed["server"]["publish_address"] = "192.0.2.80"
        tui.save(self.path, changed)
        before = self.path.read_bytes()
        ui = Mock()
        ui.choose.return_value = "0"
        with patch.object(tui, "UI", ui):
            restored = tui.restore_configuration(self.path, changed)
        self.assertEqual(restored, self.data)
        self.assertEqual(self.path.read_bytes(), before)
        ui.run.assert_not_called()
        for call in ui.page.call_args_list:
            self.assertNotIn("FAKE-SECRET-SENTINEL", repr(call))

    def test_backup_failure_prevents_overwrite_and_deployment(self):
        tui.save(self.path, self.data)
        before = self.path.read_bytes()
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["server", "apply", "quit", "yes"]
        ui.confirm.return_value = True
        def edit(data):
            data["server"]["publish_address"] = "192.0.2.80"
        with patch.object(tui.screen, "Screen", return_value=ui), patch.object(tui, "server_settings", side_effect=edit), \
                patch.object(tui, "check_backup_directory", side_effect=OSError("fixture backup failure")):
            tui.session(None, self.path, copy.deepcopy(self.data))
        self.assertEqual(self.path.read_bytes(), before)
        ui.run.assert_not_called()

    def test_backups_cannot_be_exposed_to_executor_or_redirected_by_symlink(self):
        tui.save(self.path, self.data)
        before = self.path.read_bytes()
        changed = copy.deepcopy(self.data)
        changed["server"]["workdir"] = str(tui.backup_directory(self.path))
        with self.assertRaises(tui.TuiError):
            tui.save(self.path, changed)
        destination = self.path.parent / "elsewhere"
        destination.mkdir()
        tui.backup_directory(self.path).symlink_to(destination)
        changed["server"]["workdir"] = "./work"
        changed["server"]["publish_address"] = "192.0.2.80"
        with self.assertRaises(tui.TuiError):
            tui.save(self.path, changed)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(destination.iterdir()), [])

    def test_preview_uses_unsaved_draft_and_cleans_up_without_backups(self):
        tui.save(self.path, self.data)
        before = self.path.read_bytes()
        draft = copy.deepcopy(self.data)
        draft["server"]["publish_address"] = "192.0.2.80"
        temporary_paths = []
        def run(command):
            temporary = Path(command[2])
            temporary_paths.append(temporary)
            content = tomllib.loads(temporary.read_text())
            self.assertEqual(content["server"]["publish_address"], "192.0.2.80")
            self.assertEqual(content["server"]["workdir"], str(self.path.parent / "work"))
            self.assertEqual(stat.S_IMODE(temporary.stat().st_mode), 0o600)
            self.assertEqual(self.path.read_bytes(), before)
            self.assertEqual(command[-1], "--plan")
            return 0
        with patch.object(tui, "UI", Mock(run=Mock(side_effect=run))):
            tui.preview_plan(self.path, draft)
        self.assertFalse(temporary_paths[0].exists())
        self.assertFalse(tui.backup_directory(self.path).exists())
        self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_current_toml_can_be_recovered_from_backup(self):
        tui.save(self.path, self.data)
        changed = copy.deepcopy(self.data)
        changed["server"]["publish_address"] = "192.0.2.80"
        backup = tui.save(self.path, changed)
        invalid = b"invalid = [ FAKE-SECRET-SENTINEL"
        self.path.write_bytes(invalid)
        _, error = tui.load_configuration(self.path)
        self.assertTrue(error)
        self.assertNotIn("FAKE-SECRET-SENTINEL", error)
        restored = tui.load_backup(self.path, backup)
        broken_backup = tui.save(self.path, restored)
        self.assertEqual(broken_backup.read_bytes(), invalid)
        self.assertEqual(tomllib.loads(self.path.read_text()), self.data)

    def test_field_validation_rejects_bad_addresses_and_ports(self):
        for label, value in (("Proxy IPv4 address", "ss://example"), ("Proxy port", "65536"),
                             ("Private IPv4 CIDR", "8.8.8.0/24"), ("Control network /24", "172.30.70.0/16")):
            with self.subTest(label=label):
                self.assertTrue(tui.field_error(label, value))
        self.assertFalse(tui.field_error("Proxy IPv4 address", "192.0.2.20"))
        self.assertFalse(tui.field_error("Proxy port", "10001"))

    def test_section_previews_show_values_changes_and_hide_authentication(self):
        saved = copy.deepcopy(self.data)
        self.data["server"]["publish_address"] = "192.0.2.80"
        self.data["proxy"]["password"] = "FAKE-REPLACEMENT-SECRET"
        for section, expected in (("server", "* Listen: 192.0.2.80:6768"), ("network", "192.0.2.20:1080"),
                                  ("executor", "192.0.2.21:1081"), ("lan", "172.20.1.0/24 tcp/443"),
                                  ("limits", "Memory: 8g"), ("paths", "Generated Compose")):
            preview = tui.section_preview(section, self.path, self.data, saved, True)
            self.assertIn(expected, preview)
            self.assertIn("Unsaved edits", preview)
            for secret in ("FAKE-SECRET-SENTINEL", "FAKE-SECOND-SECRET", "FAKE-REPLACEMENT-SECRET"):
                self.assertNotIn(secret, preview)
        self.assertIn("Saved: 203.0.113.10:6768", tui.section_preview("server", self.path, self.data, saved, True))
        self.assertIn("authentication changed (hidden)", tui.section_preview("network", self.path, self.data, saved, True))

    def test_navigation_updates_previews_without_enter_or_writes(self):
        tui.save(self.path, self.data)
        original = self.path.read_bytes()
        with self.terminal() as (master, _):
            output = self.read_until(master, b"Esc")
            self.assertIn(b"Client address", output)
            for marker in (b"Proxy endpoint", b"source: separate", b"Allowed destinations", b"Memory + swap", b"Generated Compose"):
                os.write(master, b"j")
                output += self.read_until(master, marker)
            os.write(master, b"\x1b[6~")
            output += self.read_until(master, b"/tmp")
            os.write(master, b"0\n")
        self.assertEqual(original, self.path.read_bytes())
        self.assertNotIn(b"FAKE-SECRET-SENTINEL", output)
        self.assertNotIn(b"FAKE-SECOND-SECRET", output)

    def test_installed_deployment_opens_management_without_starting(self):
        (self.path.parent / "compose.yaml").touch()
        ui = Mock()
        with patch.object(tui.screen, "Screen", return_value=ui), patch.object(tui, "manage_deployment", return_value="quit") as manage:
            tui.session(None, self.path, self.data)
        manage.assert_called_once()
        ui.run.assert_not_called()

    def test_successful_apply_enters_management(self):
        tui.save(self.path, self.data)
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["apply"]
        ui.confirm.return_value = True
        ui.run.return_value = 0
        with patch.object(tui.screen, "Screen", return_value=ui), patch.object(tui, "manage_deployment", return_value="quit") as manage:
            tui.session(None, self.path, copy.deepcopy(self.data))
        manage.assert_called_once()
        ui.run.assert_called_once_with([str(ROOT / "setup.sh"), "--config", str(self.path), "--apply"])

    def test_failed_apply_stays_in_configuration(self):
        tui.save(self.path, self.data)
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["apply", "quit"]
        ui.confirm.return_value = True
        ui.run.return_value = 1
        with patch.object(tui.screen, "Screen", return_value=ui), patch.object(tui, "manage_deployment") as manage:
            tui.session(None, self.path, copy.deepcopy(self.data))
        manage.assert_not_called()

    def test_saved_toml_without_deployment_shows_installation_only(self):
        tui.save(self.path, self.data)
        ui = Mock()
        ui.notes = []
        ui.choose.return_value = "quit"
        with patch.object(tui.screen, "Screen", return_value=ui), patch.object(tui, "manage_deployment") as manage:
            tui.session(None, self.path, self.data)
        items = {item[0]: item[1] for item in ui.choose.call_args.args[1]}
        self.assertNotIn("wizard", items)
        self.assertNotIn("save", items)
        self.assertIn("restore", items)
        self.assertEqual(list(items)[:6], ["server", "network", "executor", "lan", "limits", "paths"])
        self.assertEqual(items["apply"], "Install & start server")
        for action in ("auth", "manage", "pair", "start", "stop", "restart", "upgrade"):
            self.assertNotIn(action, items)
        manage.assert_not_called()
        ui.run.assert_not_called()

    def test_installed_editor_returns_to_management_without_installation_menu(self):
        (self.path.parent / "compose.yaml").touch()
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = tui.screen.Cancelled
        with patch.object(tui.screen, "Screen", return_value=ui), \
                patch.object(tui, "manage_deployment", side_effect=["configure", "quit"]) as manage:
            tui.session(None, self.path, self.data)
        self.assertEqual(manage.call_count, 2)
        items = {item[0]: item[1] for item in ui.choose.call_args.args[1]}
        self.assertEqual(items["apply"], "Apply changes")
        self.assertIn("back", items)
        self.assertIn("upgrade", items)
        for action in ("wizard", "quit", "auth", "manage", "pair"):
            self.assertNotIn(action, items)
        ui.run.assert_not_called()

    def test_return_to_management_requires_discarding_unsaved_changes(self):
        tui.save(self.path, self.data)
        before = self.path.read_bytes()
        (self.path.parent / "compose.yaml").touch()
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["server", "back", "no", "back", "yes"]
        def edit(data):
            data["server"]["publish_address"] = "192.0.2.80"
        with patch.object(tui.screen, "Screen", return_value=ui), patch.object(tui, "server_settings", side_effect=edit), \
                patch.object(tui, "manage_deployment", side_effect=["configure", "quit"]) as manage:
            tui.session(None, self.path, self.data)
        self.assertEqual(manage.call_count, 2)
        prompts = [call.args[0] for call in ui.choose.call_args_list]
        self.assertEqual(prompts.count("Discard unsaved edits and return to management?"), 2)
        self.assertEqual(self.path.read_bytes(), before)
        ui.run.assert_not_called()

    def test_stopped_deployment_stays_in_management_when_dialog_cancelled(self):
        state = {"installed": True, "error": "", "port": "not reachable", "compose": "fixture.yaml",
                 "services": {"orca-server": {"state": "exited", "status": "Exited"}}}
        ui = Mock()
        ui.notes = []
        ui.choose.side_effect = ["auth", tui.screen.Cancelled, tui.screen.Cancelled]
        with patch.object(tui, "UI", ui), patch.object(tui.manager, "snapshot", return_value=state):
            self.assertEqual(tui.manage_deployment(), "quit")
        items = {item[0] for item in ui.choose.call_args.args[1]}
        self.assertIn("auth", items)
        self.assertIn("pair", items)
        self.assertIn("pair-mobile", items)
        self.assertIn("uninstall", items)
        self.assertNotIn("wizard", items)
        self.assertNotIn("apply", items)
        self.assertEqual(ui.choose.call_count, 3)
        ui.run.assert_not_called()

    def test_uninstall_returns_to_installation_with_saved_settings(self):
        (self.path.parent / "compose.yaml").touch()
        ui = Mock()
        ui.notes = []
        ui.choose.return_value = "quit"
        with patch.object(tui.screen, "Screen", return_value=ui), \
                patch.object(tui, "manage_deployment", return_value="uninstalled"):
            tui.session(None, self.path, self.data)
        items = {item[0]: item[1] for item in ui.choose.call_args.args[1]}
        self.assertEqual(items["apply"], "Install & start server")
        self.assertNotIn("upgrade", items)

    def test_maintenance_pairing_requires_confirmation(self):
        state = {"installed": True, "error": "", "port": "reachable", "compose": "fixture.yaml", "services": {}}
        for action in ("pair", "pair-mobile"):
            for approved in (False, True):
                with self.subTest(action=action, approved=approved):
                    ui = Mock()
                    ui.choose.side_effect = [action, "quit"]
                    ui.confirm.return_value = approved
                    with patch.object(tui, "UI", ui), patch.object(tui.manager, "snapshot", return_value=state):
                        self.assertEqual(tui.manage_deployment(), "quit")
                    self.assertEqual(ui.run.call_count, int(approved))
                    if approved:
                        self.assertEqual(ui.run.call_args.args[0][-1], action)
                    preview = ui.choose.call_args.kwargs["preview"](action)
                    self.assertIn("may be interrupted", preview)
                    self.assertIn("Ctrl-C", preview)

    def test_uninstall_confirmation_cancellation_never_runs_command(self):
        state = {"installed": True, "error": "", "port": "reachable", "compose": "fixture.yaml", "services": {}}
        ui = Mock()
        ui.choose.side_effect = ["uninstall", "quit"]
        ui.confirm.return_value = False
        with patch.object(tui, "UI", ui), patch.object(tui.manager, "snapshot", return_value=state):
            self.assertEqual(tui.manage_deployment(), "quit")
        ui.run.assert_not_called()

    def test_uninstall_success_leaves_management_but_failure_stays(self):
        state = {"installed": True, "error": "", "port": "reachable", "compose": "fixture.yaml", "services": {}}
        for code, outcome in ((0, "uninstalled"), (1, "quit")):
            ui = Mock()
            ui.choose.side_effect = ["uninstall", "quit"]
            ui.confirm.return_value = True
            ui.run.return_value = code
            with patch.object(tui, "UI", ui), patch.object(tui.manager, "snapshot", return_value=state):
                self.assertEqual(tui.manage_deployment(), outcome)
            ui.run.assert_called_once_with([sys.executable, str(ROOT / "lib/server-manage.py"), "uninstall"])


if __name__ == "__main__":
    unittest.main()
