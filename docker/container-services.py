#!/usr/bin/env python3
"""Supervise application and same-UID SSH independently, without a Docker socket or root."""
import signal
import subprocess
import sys
import time

stopping = False


def stop(*_args):
    global stopping
    stopping = True


for sig in (signal.SIGTERM, signal.SIGINT):
    signal.signal(sig, stop)
commands = [sys.argv[1:], ['/usr/sbin/sshd', '-D', '-e', '-f', '/run/orca-ssh/sshd.conf']]
children = [None, None]
retry = [0.0, 0.0]
try:
    while not stopping:
        for index, command in enumerate(commands):
            child = children[index]
            if (child is None or child.poll() is not None) and time.monotonic() >= retry[index]:
                children[index] = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True)
                retry[index] = time.monotonic() + 3
        time.sleep(.2)
finally:
    for child in children:
        if child and child.poll() is None:
            child.terminate()
    deadline = time.monotonic() + 70
    for child in children:
        if child:
            try:
                child.wait(timeout=max(.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                pass  # Container shutdown owns final cleanup; never kill unrelated workers here.
