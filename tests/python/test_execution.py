"""Exercise the real executor transport with subprocesses, binary streams and cancellation."""

import base64
import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[2] / "docker" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


execution = load_module("execution", "execution.py")


class ExecutionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.environment = patch.dict(os.environ, ORCA_EXECUTOR_ROOT=str(self.root), HTTP_PROXY="test-sentinel")
        self.environment.start()
        self.server = execution.Server(("127.0.0.1", 0))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.environment.stop()
        self.temporary.cleanup()

    def request(self, argv, cwd=None, data=b""):
        with socket.create_connection(self.server.server_address, timeout=5) as conn:
            with conn.makefile("rwb") as stream:
                execution.send(stream, {"argv": argv, "cwd": str(cwd or self.root),
                                        "stdin": base64.b64encode(data).decode()})
                messages = []
                while True:
                    line = stream.readline()
                    if not line:
                        break
                    message = json.loads(line)
                    messages.append(message)
                    if "exit" in message:
                        return messages
        self.fail("executor closed without an exit status")

    @staticmethod
    def output(messages, stream):
        return b"".join(base64.b64decode(item["data"]) for item in messages if item.get("stream") == stream)

    def test_binary_stdin_stdout_stderr_and_exit_status(self):
        data = bytes(range(256)) * 1024
        messages = self.request([sys.executable, "-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read()); "
                                 "sys.stderr.write('diagnostic'); sys.exit(7)"], data=data)
        self.assertEqual(self.output(messages, "stdout"), data)
        self.assertEqual(self.output(messages, "stderr"), b"diagnostic")
        self.assertEqual(messages[-1]["exit"], 7)

    def test_execution_uses_shared_cwd_and_does_not_inherit_proxy(self):
        directory = self.root / "project"
        directory.mkdir()
        messages = self.request([sys.executable, "-c", "import os; print(os.getcwd()); "
                                 "print(any(k.lower().endswith('_proxy') for k in os.environ))"], cwd=directory)
        self.assertEqual(self.output(messages, "stdout"), f"{directory}\nFalse\n".encode())

    def test_arguments_are_not_interpreted_by_a_shell(self):
        literal = "$(touch unexpected); * `echo unexpected`"
        messages = self.request([sys.executable, "-c", "import sys; print(sys.argv[1])", literal])
        self.assertEqual(self.output(messages, "stdout"), (literal + "\n").encode())
        self.assertFalse((self.root / "unexpected").exists())

    def test_cwd_outside_workdir_and_symlink_escape_are_rejected(self):
        link = self.root / "outside"
        link.symlink_to(self.root.parent, target_is_directory=True)
        for cwd in (self.root.parent, link):
            messages = self.request([sys.executable, "-c", "raise SystemExit(0)"], cwd=cwd)
            self.assertEqual(messages[-1]["exit"], 125)
            self.assertIn("error", messages[-1])

    def test_missing_executable_has_no_shell_or_local_fallback(self):
        messages = self.request(["/missing/executable"])
        self.assertEqual(messages[-1]["exit"], 125)

    def test_background_descendant_cannot_hold_completed_command_open(self):
        started = time.monotonic()
        messages = self.request([sys.executable, "-c", "import subprocess,sys; "
                                 "subprocess.Popen([sys.executable,'-c','import time; time.sleep(30)'])"])
        self.assertEqual(messages[-1]["exit"], 0)
        self.assertLess(time.monotonic() - started, 3)

    def test_disconnect_terminates_a_quiet_process(self):
        pidfile = self.root / "child.pid"
        connection = socket.create_connection(self.server.server_address, timeout=5)
        request = {"argv": [sys.executable, "-c", "import os,time,pathlib; "
                            "pathlib.Path('child.pid').write_text(str(os.getpid())); time.sleep(30)"], "cwd": str(self.root)}
        connection.sendall(json.dumps(request).encode() + b"\n")
        deadline = time.monotonic() + 5
        while (not pidfile.exists() or not pidfile.read_text()) and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(pidfile.exists())
        pid = int(pidfile.read_text())
        connection.close()
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            self.fail("disconnected command remained running")

    def test_health_request_does_not_run_a_command(self):
        with socket.create_connection(self.server.server_address, timeout=5) as conn:
            conn.sendall(b'{"health":true}\n')
            self.assertEqual(json.loads(conn.makefile("rb").readline()), {"healthy": True})


if __name__ == "__main__":
    unittest.main()
