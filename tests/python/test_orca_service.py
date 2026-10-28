"""Process lifetime and stop-timeout regression tests without an Orca profile."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('orca_service', ROOT / 'docker/orca-service.py')
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class ServiceTests(unittest.TestCase):
    def test_stop_restart_preserves_independent_worker_and_reaps_child(self):
        worker = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(120)'])
        controller = service.Service([sys.executable, '-c', 'import time; time.sleep(120)'])
        try:
            first = controller.start()['pid']
            self.assertEqual(controller.start()['pid'], first)
            self.assertEqual(controller.stop()['state'], 'stopped')
            self.assertIsNone(worker.poll())
            self.assertNotEqual(controller.start()['pid'], first)
            self.assertIsNone(worker.poll())
        finally:
            controller.stop()
            worker.terminate()
            worker.wait()

    def test_stop_timeout_does_not_kill_or_replace_child(self):
        with tempfile.TemporaryDirectory() as directory:
            ready = Path(directory) / 'ready'
            command = [sys.executable, '-c', 'import signal,time,pathlib; signal.signal(signal.SIGTERM, signal.SIG_IGN); pathlib.Path(__import__("sys").argv[1]).touch(); time.sleep(120)', str(ready)]
            controller = service.Service(command)
            try:
                pid = controller.start()['pid']
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertTrue(ready.exists())
                self.assertFalse(controller.stop(timeout=.05)['ok'])
                self.assertEqual(controller.start()['pid'], pid)
            finally:
                controller.child.kill()
                controller.child.wait()

    def test_exited_child_can_be_started_again(self):
        controller = service.Service([sys.executable, '-c', 'raise SystemExit(7)'])
        controller.start()
        controller.child.wait()
        self.assertEqual(controller.status()['exit_code'], 7)
        first = controller.child.pid
        controller.start()
        self.assertNotEqual(controller.child.pid, first)
        controller.child.wait()

    def test_pairing_disconnect_restores_normal_child_and_keeps_flags(self):
        import base64
        import json
        import socket
        import threading
        command = [sys.executable, '-u', '-c',
                   'import sys,time; print("MOBILE QR FIXTURE" if "--mobile-pairing" in sys.argv else "NORMAL", flush=True); time.sleep(120)',
                   '--supervise', '--no-pairing']
        controller = service.Service(command)
        controller.start()
        old_pid = controller.child.pid
        server, client = socket.socketpair()
        server.settimeout(2)
        client.settimeout(5)
        thread = threading.Thread(target=service.pairing, args=(controller, server, True, lambda: False))
        thread.start()
        try:
            frame = json.loads(client.makefile('rb').readline())
            self.assertIn(b'MOBILE QR FIXTURE', base64.b64decode(frame['output']))
            client.close()
            thread.join(timeout=8)
            self.assertFalse(thread.is_alive())
            self.assertEqual(controller.command, command)
            self.assertEqual(controller.status()['state'], 'running')
            self.assertNotEqual(controller.child.pid, old_pid)
        finally:
            client.close()
            server.close()
            thread.join(timeout=12)
            controller.stop()

    def test_pairing_stop_timeout_does_not_spawn_a_second_runtime(self):
        import json
        import socket
        from unittest.mock import patch
        controller = service.Service(['unused'])
        server, client = socket.socketpair()
        try:
            with patch.object(controller, 'stop', return_value={'ok': False, 'error': 'Stop timed out'}), \
                    patch.object(service.subprocess, 'Popen') as spawn:
                service.pairing(controller, server, True, lambda: False)
                spawn.assert_not_called()
                self.assertFalse(json.loads(client.recv(4096))['ok'])
        finally:
            server.close()
            client.close()

    def test_expired_pairing_lease_restores_previously_stopped_state(self):
        import socket
        from unittest.mock import patch
        controller = service.Service([sys.executable, '-u', '-c', 'import time; print("QR FIXTURE"); time.sleep(120)', '--no-pairing'])
        server, client = socket.socketpair()
        try:
            # No heartbeat arrives. Advance only the lease clock, without a ten-second sleep.
            with patch.object(service.time, 'monotonic', side_effect=[0, 0, 11]):
                service.pairing(controller, server, True, lambda: False)
            self.assertEqual(controller.status()['state'], 'stopped')
        finally:
            controller.stop()
            server.close()
            client.close()
