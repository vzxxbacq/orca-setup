#!/usr/bin/env python3
"""Keep container lifetime independent of Orca; control only the tracked CLI child."""
import base64
import json
import selectors
import threading
import time
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys

DIRECTORY = Path('/tmp/orca-service')
SOCKET = DIRECTORY / 'control.sock'


def request(action):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(80)
        client.connect(str(SOCKET))
        client.sendall((action + '\n').encode())
        stream = client.makefile('rb')
        response = json.loads(stream.readline(4096))
        print(json.dumps(response), flush=True)
        return 0 if response['ok'] else 1


class Service:
    def __init__(self, command):
        self.command = command
        self.child = None

    def status(self):
        code = self.child.poll() if self.child else None
        running = self.child is not None and code is None
        return {'ok': True, 'state': 'running' if running else 'stopped',
                'pid': self.child.pid if running else None, 'exit_code': code, 'maintenance_pairing': 1}

    def start(self):
        if self.status()['state'] != 'running':
            # A separate session prevents terminal signals from reaching unrelated workers.
            self.child = subprocess.Popen(self.command, stdin=subprocess.DEVNULL, start_new_session=True)
        return self.status()

    def stop(self, timeout=60):
        if self.status()['state'] == 'running':
            # Never signal a process group or force-kill agent descendants.
            self.child.terminate()
            try:
                self.child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                return {'ok': False, 'state': 'stopping',
                        'error': 'Orca did not exit in time; no replacement was started and no process was force-killed.'}
        return self.status()

    def perform(self, action):
        if action == 'status':
            return self.status()
        if action == 'stop':
            return self.stop()
        if action == 'restart':
            result = self.stop()
            if not result['ok']:
                return result
        if action in ('start', 'restart'):
            return self.start()
        return {'ok': False, 'error': 'Unknown service action.'}



def send_frame(client, value):
    client.sendall((json.dumps(value) + '\n').encode())


def pairing_client(action):
    """Stream offers to the interactive caller only; stdin carries the host lease."""
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(str(SOCKET))
        client.sendall((action + '\n').encode())

        def lease():
            try:
                while True:
                    if sys.stdin.isatty():
                        time.sleep(1)
                    elif not os.read(sys.stdin.fileno(), 1):
                        break
                    client.sendall(b'.')
            except OSError:
                pass
            finally:
                try:
                    client.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

        threading.Thread(target=lease, daemon=True).start()
        pending = b''
        warning = b'[agent-state-rules] download failed: HTTP 404'
        explanation = b'[agent-state-rules] Optional upstream rules are unavailable (HTTP 404); keeping local rules. Pairing can continue.'
        for line in client.makefile('rb'):
            frame = json.loads(line)
            if 'output' in frame:
                pending += base64.b64decode(frame['output'])
                # Retain only an incomplete line in memory; offers still go only to the terminal.
                while b'\n' in pending:
                    output, pending = pending.split(b'\n', 1)
                    sys.stdout.buffer.write(output.replace(warning, explanation) + b'\n')
                if len(pending) > 16384:
                    sys.stdout.buffer.write(pending)
                    pending = b''
                sys.stdout.buffer.flush()
            else:
                sys.stdout.buffer.write(pending.replace(warning, explanation))
                sys.stdout.buffer.flush()
                print(frame.get('message', ''), flush=True)
                return 0 if frame.get('ok') else 1
    return 1


def pairing(service, client, mobile, shutting_down):
    """Exclusive maintenance session; always restore after EOF, expired lease or failure."""
    was_running = service.status()['state'] == 'running'
    normal_command = service.command
    result = service.stop()
    if not result['ok']:
        send_frame(client, {'ok': False, 'message': result['error']})
        return
    try:
        service.command = [arg for arg in normal_command if arg not in ('--supervise', '--no-pairing', '--mobile-pairing')]
        if mobile:
            service.command.append('--mobile-pairing')
        service.child = subprocess.Popen(service.command, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        last_heartbeat = time.monotonic()
        with selectors.DefaultSelector() as selector:
            selector.register(client, selectors.EVENT_READ)
            selector.register(service.child.stdout, selectors.EVENT_READ)
            while not shutting_down() and time.monotonic() - last_heartbeat < 10:
                for key, _ in selector.select(timeout=.5):
                    if key.fileobj is client:
                        if not client.recv(1024):
                            return
                        last_heartbeat = time.monotonic()
                    else:
                        output = os.read(service.child.stdout.fileno(), 8192)
                        if not output:
                            return
                        if output:
                            send_frame(client, {'output': base64.b64encode(output).decode()})
    finally:
        pairing_exit = service.child.poll() if service.child else None
        result = service.stop()
        if pairing_exit is None and service.child and service.child.returncode and service.child.returncode > 0:
            pairing_exit = service.child.returncode
        if service.child and service.child.stdout:
            service.child.stdout.close()
        service.command = normal_command
        if result['ok'] and was_running and not shutting_down():
            service.start()
        try:
            if not result['ok']:
                message = result['error']
            elif pairing_exit not in (None, 0):
                message = 'Pairing runtime failed. Previous Orca process state was restored.'
            elif was_running and not shutting_down():
                message = 'Pairing ended. Normal Orca service restored.'
            else:
                message = 'Pairing ended. Orca remains stopped.'
            send_frame(client, {'ok': result['ok'] and pairing_exit in (None, 0), 'message': message})
        except OSError:
            pass


def serve(command):
    DIRECTORY.mkdir(mode=0o700, exist_ok=True)
    if DIRECTORY.is_symlink() or DIRECTORY.stat().st_uid != os.getuid():
        raise ValueError('Invalid service directory.')
    DIRECTORY.chmod(0o700)
    # A lock prevents a second manager from replacing a live control socket.
    import fcntl
    with os.fdopen(os.open(DIRECTORY / 'manager.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), 'w') as lock, socket.socket(socket.AF_UNIX) as listener:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        SOCKET.unlink(missing_ok=True)
        listener.bind(str(SOCKET))
        SOCKET.chmod(0o600)
        listener.listen(8)
        listener.settimeout(0.5)
        service = Service(command)
        stopping = False

        def shutdown(*_args):
            nonlocal stopping
            stopping = True

        for sig in (signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, shutdown)
        try:
            service.start()
            while not stopping:
                service.status()  # Reap an exited CLI even when no client connects.
                try:
                    client, _ = listener.accept()
                except socket.timeout:
                    continue
                with client:
                    client.settimeout(2)
                    try:
                        # Read only the request line; heartbeat bytes must remain on the socket.
                        data = b''
                        while not data.endswith(b'\n') and len(data) < 64:
                            byte = client.recv(1)
                            if not byte:
                                break
                            data += byte
                        action = data.decode().strip()
                        if action in ('pair', 'pair-mobile'):
                            pairing(service, client, action == 'pair-mobile', lambda: stopping)
                            continue
                        result = service.perform(action)
                        client.sendall((json.dumps(result) + '\n').encode())
                    except (OSError, ValueError):
                        pass
        finally:
            service.stop()
            SOCKET.unlink(missing_ok=True)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == 'run':
        serve(sys.argv[2:])
        return 0
    if len(sys.argv) == 2 and sys.argv[1] in ('pair', 'pair-mobile'):
        return pairing_client(sys.argv[1])
    if len(sys.argv) == 2 and sys.argv[1] in ('start', 'stop', 'restart', 'status'):
        return request(sys.argv[1])
    raise ValueError('Choose run COMMAND..., start, stop, restart or status.')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError):
        print('Orca service control unavailable. Apply the updated deployment during a maintenance window; no container restart was attempted.', file=sys.stderr)
        sys.exit(1)
