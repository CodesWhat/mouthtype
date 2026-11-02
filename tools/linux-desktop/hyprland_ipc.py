"""A minimal client for Hyprland's request socket, so a hot path doesn't spawn hyprctl for every query."""
import os
from pathlib import Path
import socket
import time


class IPCError(OSError):
    """sent is False when the request never left this process, which makes a retry through hyprctl safe."""
    def __init__(self, message, sent=False):
        super().__init__(message)
        self.sent = sent


class IPCTimeout(IPCError):
    pass


class HyprlandIPC:
    MAX_REPLY = 1 << 20

    def __init__(self, env=None):
        self.env = os.environ if env is None else env

    def socket_path(self):
        signature = self.env.get('HYPRLAND_INSTANCE_SIGNATURE')
        if not signature or '/' in signature:
            raise IPCError('No Hyprland instance')
        runtime = self.env.get('XDG_RUNTIME_DIR')
        candidates = ([Path(runtime) / 'hypr' / signature / '.socket.sock'] if runtime else [])
        candidates.append(Path('/tmp/hypr') / signature / '.socket.sock')
        for path in candidates:
            if path.exists():
                return str(path)
        raise IPCError('No Hyprland socket')

    def request(self, command, timeout):
        """The reply text for one request such as 'j/activewindow' or '/dispatch ...', as hyprctl would send it."""
        deadline = time.monotonic() + timeout
        path = self.socket_path()
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sent = False
        try:
            connection.settimeout(timeout)
            connection.connect(path)
            sent = True
            connection.sendall(command.encode('utf-8'))
            chunks, size = [], 0
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise socket.timeout()
                connection.settimeout(remaining)
                chunk = connection.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
                if size > self.MAX_REPLY:
                    raise IPCError('Reply too large', sent=True)
            return b''.join(chunks).decode('utf-8')
        except socket.timeout:
            raise IPCTimeout('Hyprland did not answer in time', sent=sent) from None
        except IPCError:
            raise
        except (OSError, UnicodeDecodeError) as error:
            raise IPCError(str(error), sent=sent) from error
        finally:
            connection.close()
