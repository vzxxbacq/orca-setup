#!/usr/bin/env python3
"""Run a command on a pseudo-terminal and type one line into it, like a user at a prompt.

Usage: PTY_INPUT=<line> pty.py <prompt text> <command> [args...]

Waits until the command has printed <prompt text> and the terminal no longer echoes input (the hidden prompt is
ready), then types PTY_INPUT and Enter. Prints everything the terminal showed, including any echo, and exits with
the command's status. Exits 3 when the prompt never appears or echo stays on; nothing is typed then.
"""
import fcntl
import os
import select
import sys
import termios
import time

TIMEOUT = 20


def read_ready(fd, wait):
    """What the terminal shows within `wait` seconds (empty when nothing)."""
    ready, _, _ = select.select([fd], [], [], wait)
    if not ready:
        return b''
    try:
        return os.read(fd, 4096)
    except OSError:
        return b''


def main():
    prompt, command = sys.argv[1].encode(), sys.argv[2:]
    line = os.environ.get('PTY_INPUT', '').encode()
    master, slave = os.openpty()
    pid = os.fork()
    if pid == 0:
        os.close(master)
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        for target in (0, 1, 2):
            os.dup2(slave, target)
        if slave > 2:
            os.close(slave)
        os.execvp(command[0], command)
    # The parent keeps the terminal side open to read its echo flag.
    seen = b''
    typed = False
    status = None
    deadline = time.monotonic() + TIMEOUT
    while status is None:
        if not typed and prompt in seen and not termios.tcgetattr(slave)[3] & termios.ECHO:
            os.write(master, line + b'\r')
            typed = True
        seen += read_ready(master, 0.05)
        done, code = os.waitpid(pid, os.WNOHANG)
        if done:
            status = code
        elif time.monotonic() > deadline:
            os.kill(pid, 9)
            status = os.waitpid(pid, 0)[1]
    while True:
        chunk = read_ready(master, 0.2)
        if not chunk:
            break
        seen += chunk
    sys.stdout.write(seen.decode('utf-8', 'replace'))
    if not typed:
        sys.exit(3)
    sys.exit(os.waitstatus_to_exitcode(status))


main()
