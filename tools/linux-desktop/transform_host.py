"""Resident model host for Transform Selection.

Each `transform run` is its own short-lived CLI process, so a llama-server started there dies with it and every
transform pays the full load. When the daemon already runs this model, transforms use its server and this host never starts. Otherwise this
host keeps one cleanup engine (the same CleanupEngine, worker and llama-server
the dictation cleanup uses) alive between transforms and exits on its own after an idle timeout.

Lifetime, so a server is never left orphaned:
- one host per runtime directory, owned by an flock on transform-host.lock (released by the kernel if the host dies);
- the host stops after `idle` seconds without a request, on SIGTERM, and when the daemon exits (`stop`);
- llama-server runs under the engine's guarded worker, which kills its process group if the host dies without cleanup.

Protocol: one JSON line each way on transform-host.sock (mode 0600). Closing the connection cancels the request.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import threading
import time

SOCKET = 'transform-host.sock'
LOCK = 'transform-host.lock'
PIDFILE = 'transform-host.pid'
DEFAULT_IDLE_SECONDS = 60.0
MAXIMUM_IDLE_SECONDS = 24 * 60 * 60.0
MAXIMUM_REQUEST = 256 * 1024
IDLE_VARIABLE = 'MOUTHTYPE_TRANSFORM_IDLE_SECONDS'


def idle_seconds(environ=None):
    """Seconds the model stays resident after a transform. 0 turns residency off. Bad values use the default."""
    raw = (os.environ if environ is None else environ).get(IDLE_VARIABLE)
    if raw in (None, ''):
        return DEFAULT_IDLE_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_IDLE_SECONDS
    if value != value or value < 0:
        return DEFAULT_IDLE_SECONDS
    return min(value, MAXIMUM_IDLE_SECONDS)


def alive(runtime):
    """True while a host holds the lock. The kernel drops the lock with the process, so this is never stale."""
    try:
        descriptor = os.open(Path(runtime) / LOCK, os.O_RDONLY)
    except OSError:
        return False
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        except OSError:
            return False
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        return False
    finally:
        os.close(descriptor)


def _read_line(connection, limit=MAXIMUM_REQUEST):
    data = b''
    while b'\n' not in data:
        chunk = connection.recv(65536)
        if not chunk:
            raise ValueError('Incomplete request')
        data += chunk
        if len(data) > limit:
            raise ValueError('Request exceeds limit')
    return json.loads(data.split(b'\n', 1)[0])


def _peer_closed(connection):
    try:
        return connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b''
    except BlockingIOError:
        return False
    except OSError:
        return True


def _engine_class():
    import desktop

    class Engine(desktop.CleanupEngine):
        def _prime(self):
            pass

        def load(self, cancelled):
            with self.lock:
                self._ensure_loaded(cancelled)

    return Engine


class Host:
    def __init__(self, *, worker, load_seconds, hash_cache=None, engine_class=None):
        self.worker, self.load_seconds, self.hash_cache = worker, load_seconds, hash_cache
        self.engine_class = engine_class
        self.engine, self.key = None, None

    def _engine_for(self, settings):
        key = json.dumps(settings, sort_keys=True)
        if self.engine is not None and (key != self.key or self.engine.worker is None or
                                        self.engine.state != 'ready'):
            self.close()
        if self.engine is None:
            self.engine_class = self.engine_class or _engine_class()
            self.engine = self.engine_class(settings, worker=self.worker, startup_seconds=self.load_seconds,
                                            hash_cache=self.hash_cache)
            self.key = key
        return self.engine

    def handle(self, connection, request):
        """The reply for one transform request, or None when the client went away first."""
        settings, kind, text, seconds = (request.get(name) for name in ('settings', 'kind', 'text', 'seconds'))
        if (not isinstance(settings, dict) or not isinstance(kind, str) or not isinstance(text, str) or
                type(seconds) not in (int, float) or not 0 < seconds <= 600):
            return {'error': 'invalid_request'}
        cancelled, box = threading.Event(), {}

        def work():
            try:
                engine = self._engine_for(settings)
                engine.load(cancelled)
                box['text'] = engine.clean(text, cancelled, seconds=seconds, controls=kind)
            except BaseException as error:
                box['error'] = error

        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        while thread.is_alive():
            thread.join(.05)
            if not cancelled.is_set() and _peer_closed(connection):
                cancelled.set()
        if cancelled.is_set():
            return None
        if 'error' in box:
            return {'error': type(box['error']).__name__}
        if box['text'] is None:
            return {'timeout': True}
        return {'text': box['text']}

    def close(self):
        engine, self.engine, self.key = self.engine, None, None
        if engine is not None:
            engine.close()


def serve(runtime, *, worker, idle, load_seconds, hash_cache=None, stopped=None, clock=time.monotonic,
          lock_wait=3.0, engine_class=None):
    """Run the host until idle, stopped or told to shut down. Returns 0, or 1 if another host owns the runtime."""
    runtime = Path(runtime)
    stopped = stopped or threading.Event()
    with open(runtime / LOCK, 'a') as ownership:
        os.chmod(ownership.name, 0o600)
        end = clock() + lock_wait
        while True:
            try:
                fcntl.flock(ownership, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                # A host that is idling out still holds the lock for a moment; wait for it rather than lose the race.
                if clock() >= end:
                    return 1
                time.sleep(.05)
        path = runtime / SOCKET
        if path.exists() or path.is_symlink():
            info = path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError('Refusing to replace runtime path')
            path.unlink()
        pidfile = runtime / PIDFILE
        pidfile.write_text(str(os.getpid()))
        os.chmod(pidfile, 0o600)
        host = Host(worker=worker, load_seconds=load_seconds, hash_cache=hash_cache, engine_class=engine_class)
        try:
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(path))
                os.chmod(path, 0o600)
                server.listen(4)
                server.settimeout(.1)
                last = clock()
                while not stopped.is_set() and clock() - last < idle:
                    try:
                        connection, _ = server.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        try:
                            connection.settimeout(2)
                            request = _read_line(connection)
                            if not isinstance(request, dict):
                                raise ValueError('Invalid request')
                            if request.get('action') == 'shutdown':
                                connection.sendall(b'{"state":"stopping"}\n')
                                break
                            if request.get('action') != 'run':
                                raise ValueError('Unknown action')
                            connection.settimeout(None)
                            reply = host.handle(connection, request)
                        except (OSError, ValueError, TypeError):
                            reply = {'error': 'invalid_request'}
                        if reply is not None:
                            try:
                                connection.sendall(json.dumps(reply, ensure_ascii=False).encode() + b'\n')
                            except OSError:
                                pass
                    last = clock()
        finally:
            try:
                host.close()
            finally:
                path.unlink(missing_ok=True)
                pidfile.unlink(missing_ok=True)
    return 0


def host_command(runtime, *, worker, idle, load_seconds, hash_cache=None):
    command = [sys.executable, str(Path(__file__).resolve()), '--runtime', str(runtime), '--idle', str(idle),
               '--load-seconds', str(load_seconds)]
    if worker is not None:
        command += ['--worker', str(worker)]
    if hash_cache is not None:
        command += ['--hash-cache', str(hash_cache.path)]
        if hash_cache.force:
            command.append('--force-verify')
    return command


def _connect(runtime):
    connection = socket.socket(socket.AF_UNIX)
    try:
        connection.settimeout(1)
        connection.connect(str(Path(runtime) / SOCKET))
    except OSError:
        connection.close()
        raise
    return connection


def ask(runtime, request, cancelled, *, command, seconds, spawn_seconds=10):
    """One request to the host, starting it first if none is running. None when cancelled or past `seconds`."""
    runtime = Path(runtime)
    runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
    started = time.monotonic()
    connection, process = None, None
    while connection is None:
        if cancelled.is_set() or time.monotonic() - started >= seconds:
            return None
        try:
            connection = _connect(runtime)
        except OSError:
            if process is None:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                           stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
                threading.Thread(target=process.wait, daemon=True).start()
                spawned = time.monotonic()
            elif time.monotonic() - spawned >= spawn_seconds or process.poll() not in (None, 0):
                raise RuntimeError('Model host unavailable') from None
            time.sleep(.05)
    with connection:
        connection.settimeout(.05)
        raw = json.dumps({'action': 'run', **request}, ensure_ascii=False).encode() + b'\n'
        if len(raw) > MAXIMUM_REQUEST:
            raise ValueError('Request exceeds limit')
        offset = 0
        while offset < len(raw):
            if cancelled.is_set() or time.monotonic() - started >= seconds:
                return None
            try:
                offset += connection.send(raw[offset:])
            except socket.timeout:
                continue
        data = b''
        while b'\n' not in data:
            if cancelled.is_set() or time.monotonic() - started >= seconds:
                return None
            try:
                chunk = connection.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                raise RuntimeError('Model host stopped')
            data += chunk
            if len(data) > 2 * 1024 * 1024:
                raise ValueError('Reply exceeds limit')
    reply = json.loads(data.split(b'\n', 1)[0])
    if not isinstance(reply, dict):
        raise ValueError('Invalid reply')
    return reply


def stop(runtime, *, wait=3.0):
    """Ask the host to exit, then make sure it did. Quick when none is running."""
    runtime = Path(runtime)
    if not alive(runtime):
        return
    try:
        with _connect(runtime) as connection:
            connection.sendall(b'{"action":"shutdown"}\n')
            connection.settimeout(1)
            connection.recv(64)
    except OSError:
        pass
    for number, limit in ((None, wait), (signal.SIGTERM, 3.0), (signal.SIGKILL, 1.0)):
        if number is not None:
            try:
                # The lock is held, and the holder writes its pid under it, so this names the live host.
                os.kill(int((runtime / PIDFILE).read_text()), number)
            except (OSError, ValueError):
                return
        end = time.monotonic() + limit
        while time.monotonic() < end:
            if not alive(runtime):
                return
            time.sleep(.05)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--worker', type=Path, default=Path(__file__).with_name('transform_worker.py'))
    parser.add_argument('--idle', type=float, required=True)
    parser.add_argument('--load-seconds', type=float, required=True)
    parser.add_argument('--hash-cache', type=Path)
    parser.add_argument('--force-verify', action='store_true')
    args = parser.parse_args(argv)
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'linux-engine-proof'))
    from proof import VerifiedHashes
    cache = VerifiedHashes(args.hash_cache, force=args.force_verify) if args.hash_cache else None
    stopped = threading.Event()
    for event in (signal.SIGINT, signal.SIGTERM):
        signal.signal(event, lambda *_: stopped.set())
    try:
        return serve(args.runtime, worker=args.worker, idle=args.idle, load_seconds=args.load_seconds,
                     hash_cache=cache, stopped=stopped)
    except (OSError, ValueError):
        return 2


if __name__ == '__main__':
    sys.exit(main())
