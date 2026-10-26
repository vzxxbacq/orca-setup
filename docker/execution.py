#!/usr/bin/env python3
"""Non-interactive command execution on the isolated control network. No Docker API or agent state access."""

import argparse
import base64
import json
import os
from pathlib import Path
import select
import selectors
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading

MAX_REQUEST = 2 * 1024 * 1024
PROXY_ENV = {"http_proxy", "https_proxy", "all_proxy", "no_proxy", "ftp_proxy", "git_proxy_command"}


def send(stream, message):
    stream.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
    stream.flush()


def validate_request(request, root):
    if not isinstance(request, dict):
        raise ValueError("request must be an object")
    argv = request.get("argv")
    if not isinstance(argv, list) or not argv or len(argv) > 4096:
        raise ValueError("argv must be a nonempty array")
    if any(not isinstance(arg, str) or "\0" in arg for arg in argv) or not argv[0]:
        raise ValueError("argv contains an invalid argument")
    cwd = request.get("cwd")
    if not isinstance(cwd, str) or not Path(cwd).is_absolute():
        raise ValueError("cwd must be an absolute path")
    cwd = Path(cwd).resolve(strict=True)
    if not cwd.is_dir() or not cwd.is_relative_to(root):
        raise ValueError("cwd must be inside the shared work directory")
    data = request.get("stdin", "")
    if not isinstance(data, str):
        raise ValueError("stdin must be base64 text")
    return argv, cwd, base64.b64decode(data, validate=True)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        process = None
        try:
            self.connection.settimeout(5)
            raw = self.rfile.readline(MAX_REQUEST + 1)
            if len(raw) > MAX_REQUEST or not raw.endswith(b"\n"):
                raise ValueError("request is too large or incomplete")
            request = json.loads(raw)
            if request == {"health": True}:
                send(self.wfile, {"healthy": True})
                return
            root = Path(os.environ["ORCA_EXECUTOR_ROOT"]).resolve(strict=True)
            argv, cwd, data = validate_request(request, root)
            env = {key: value for key, value in os.environ.items() if key.lower() not in PROXY_ENV}
            self.connection.settimeout(None)
            with tempfile.TemporaryFile() as stdin:
                stdin.write(data)
                stdin.seek(0)
                process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=stdin,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           start_new_session=True)
                with selectors.DefaultSelector() as output:
                    output.register(process.stdout, selectors.EVENT_READ, "stdout")
                    output.register(process.stderr, selectors.EVENT_READ, "stderr")
                    while output.get_map():
                        if select.select([self.connection], [], [], 0)[0]:
                            # No further client messages are accepted. EOF/cancellation terminates the process group.
                            raise ConnectionError("client disconnected")
                        for key, _ in output.select(timeout=0.2):
                            chunk = os.read(key.fileobj.fileno(), 32768)
                            if chunk:
                                send(self.wfile, {"stream": key.data, "data": base64.b64encode(chunk).decode()})
                            else:
                                output.unregister(key.fileobj)
                        if process.poll() is not None:
                            # A completed command must not hang forever because a background descendant inherited pipes.
                            try:
                                os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                    code = process.wait()
                    send(self.wfile, {"exit": code if code >= 0 else 128 - code})
        except (OSError, ValueError, KeyError, TypeError) as error:
            try:
                # Avoid echoing raw requests, argv, environment values or filesystem contents.
                send(self.wfile, {"error": "execution request failed", "kind": type(error).__name__, "exit": 125})
            except OSError:
                pass
        finally:
            if process is not None:
                # Also terminate surviving descendants after the main command exits or the client disconnects.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                process.stdout.close()
                process.stderr.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address):
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(address, Handler)

    def process_request(self, request, client_address):
        if self.slots.acquire(blocking=False):
            try:
                super().process_request(request, client_address)
            except BaseException:
                self.slots.release()
                raise
        else:
            self.shutdown_request(request)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass  # No request, command or internal address is logged.


def client(arguments):
    parser = argparse.ArgumentParser(prog="orca-exec", description=__doc__)
    parser.add_argument("--cwd", default=os.getcwd(), help="directory inside the shared workdir (default: current directory)")
    parser.add_argument("--stdin", action="store_true", help="read up to 1 MiB from stdin; no TTY is allocated")
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args(arguments)
    argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
    if not argv:
        parser.error("a command is required after --")
    host = os.environ.get("ORCA_EXECUTOR_HOST")
    if not host:
        parser.error("the isolated executor is not configured; use --network-mode isolated on the Docker host")
    data = sys.stdin.buffer.read(1024 * 1024 + 1) if args.stdin else b""
    if len(data) > 1024 * 1024:
        parser.error("stdin exceeds 1 MiB")
    request = {"argv": argv, "cwd": str(Path(args.cwd).resolve()), "stdin": base64.b64encode(data).decode()}
    if len(json.dumps(request).encode()) + 1 > MAX_REQUEST:
        parser.error("request exceeds 2 MiB")
    with socket.create_connection((host, 7777), timeout=5) as connection:
        connection.settimeout(None)
        with connection.makefile("rwb") as stream:
            send(stream, request)
            while True:
                line = stream.readline(MAX_REQUEST + 1)
                if not line or len(line) > MAX_REQUEST:
                    raise ConnectionError("executor disconnected before reporting an exit status")
                message = json.loads(line)
                if "stream" in message:
                    output = sys.stdout.buffer if message["stream"] == "stdout" else sys.stderr.buffer
                    output.write(base64.b64decode(message["data"], validate=True))
                    output.flush()
                if "error" in message:
                    print("orca-exec: execution failed (check the command and shared working directory)", file=sys.stderr)
                if "exit" in message:
                    return message["exit"]


def main():
    mode = sys.argv[1]
    if mode == "server":
        with Server((os.environ["ORCA_EXECUTOR_BIND"], 7777)) as server:
            server.serve_forever()
    elif mode == "health":
        with socket.create_connection((os.environ["ORCA_EXECUTOR_BIND"], 7777), timeout=2) as conn:
            conn.sendall(b'{"health":true}\n')
            if json.loads(conn.makefile("rb").readline(1024)) != {"healthy": True}:
                return 1
    elif mode == "client":
        return client(sys.argv[2:])
    else:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError) as exc:
        print(f"orca-exec: {type(exc).__name__}; no local execution fallback", file=sys.stderr)
        sys.exit(125)
