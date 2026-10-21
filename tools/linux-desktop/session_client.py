"""Smallest client for the service socket: one JSON line out, one JSON line back.

desktop.py re-exports request and read_message, and the Omarchy control helper imports this module
directly so a hotkey press does not pay for the whole service's imports."""

import json
import os
from pathlib import Path
import socket
import time


def default_socket():
    base = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid())))
    return base / 'mouthtype' / 'session.sock'


def read_message(connection, maximum=4096):
    raw = b''
    while b'\n' not in raw:
        chunk = connection.recv(min(1024, maximum + 1 - len(raw)))
        if not chunk:
            raise ValueError('Incomplete command')
        raw += chunk
        if len(raw) > maximum:
            raise ValueError('Command exceeds limit')
    line, rest = raw.split(b'\n', 1)
    if rest:
        raise ValueError('One command per connection')
    return json.loads(line)


def request(path, action, identity=None, **fields):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2.5)
        connection.connect(str(path))
        connection.sendall(json.dumps({'action': action, 'id': identity,
                                       'admit_before': time.monotonic() + 1.5, **fields}).encode() + b'\n')
        return read_message(connection, maximum=16384)
