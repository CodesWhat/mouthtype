"""Mouthtype Linux session service and compositor command client."""

import argparse
import fcntl
import json
import math
import os
import re
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
import wave

PROOF = Path(__file__).resolve().parents[1] / 'linux-engine-proof'
sys.path.insert(0, str(PROOF))
from proof import Stopped, Worker, verify_artifacts


def private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        output.write(data)


class Session:
    def __init__(self, capture, engine, delivery, recovery, *, maximum_seconds=60, clock=None):
        self.capture, self.engine, self.delivery = capture, engine, delivery
        self.recovery = Path(recovery)
        self.recovery.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.recovery.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Recovery directory must be private and owned by you')
        self.maximum_seconds, self.clock = maximum_seconds, clock or time.monotonic
        self.lock = threading.RLock()
        self.state, self.error, self.outcome = 'idle', None, 'not_attempted'
        self.thread = None
        self.cancelled = threading.Event()
        self.take = None
        self.closed = False

    def status(self):
        return {'state': self.state, 'error': self.error, 'delivery': self.outcome,
                'recovery': self.take.name if self.take else None,
                'context': 'unsupported', 'secure_field_detection': 'unsupported',
                'delivery_verified': False}

    def command(self, action):
        with self.lock:
            if action == 'status':
                return self.status()
            if self.closed:
                raise ValueError('Session is closed')
            if action == 'toggle':
                action = 'stop' if self.state == 'recording' else 'start'
            if action == 'start' and self.state == 'idle':
                if len(list(self.recovery.iterdir())) >= 50:
                    self.error = 'recovery_full'
                    return self.status()
                self.take = self.recovery / uuid.uuid4().hex
                self.take.mkdir(mode=0o700)
                self.target = self.delivery.snapshot()
                self.cancelled = threading.Event()
                self.error, self.outcome = None, 'not_attempted'
                try:
                    self.capture.start(self.take / 'recording.wav')
                except (OSError, ValueError, subprocess.SubprocessError):
                    self.capture.cancel()
                    self.error = 'capture_unavailable'
                    return self.status()
                self.started, self.state = self.clock(), 'recording'
            elif action == 'stop' and self.state == 'recording':
                try:
                    self.capture.stop()
                except (OSError, ValueError, subprocess.SubprocessError):
                    self.capture.cancel()
                    self.state, self.error = 'idle', 'capture_interrupted'
                    return self.status()
                self.state = 'transcribing'
                self.thread = threading.Thread(target=self._finish, args=(self.take, self.cancelled, self.target))
                self.thread.start()
            elif action == 'cancel':
                if self.state != 'idle':
                    self._cancel(discard=True)
            elif action not in ('start', 'stop'):
                raise ValueError('Unknown action')
            return self.status()

    def _cancel(self, *, discard):
        self.cancelled.set()
        if self.state == 'recording':
            self.capture.cancel()
        self.state = 'cancelling' if self.state == 'transcribing' and self.thread and self.thread.is_alive() else 'idle'
        self.outcome = 'not_attempted'
        if discard and self.take:
            # Only the current recording is disposable. A completed transcript remains recoverable.
            (self.take / 'recording.wav').unlink(missing_ok=True)
            try:
                self.take.rmdir()
            except OSError:
                pass

    def _finish(self, take, cancelled, target, allow_delivery=True):
        try:
            text = self.engine.transcribe(take / 'recording.wav', cancelled)
            if not isinstance(text, str):
                raise ValueError('Invalid transcript')
            with self.lock:
                if cancelled.is_set() or self.closed:
                    return
                private_write(take / 'transcript.txt', text)
                self.outcome = 'empty' if not text else 'recover_only' if not allow_delivery else 'target_changed'
                if allow_delivery and text and target == self.delivery.snapshot():
                    self.outcome = self.delivery.submit(text, target)
                # Audio remains available after delivery uncertainty; success is never inferred.
                self.state = 'idle'
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            with self.lock:
                if not cancelled.is_set() and not self.closed:
                    self.error, self.state = 'transcription_failed', 'idle'
        finally:
            with self.lock:
                if cancelled.is_set() and self.cancelled is cancelled and self.state == 'cancelling':
                    self.state = 'idle'

    def recover_audio(self, identity):
        with self.lock:
            if self.closed or self.state != 'idle':
                return self.status()
            take = recovery_path(self.recovery, identity)
            if (take / 'transcript.txt').exists():
                return self.status()
            if not (take / 'recording.wav').is_file():
                raise ValueError('No saved audio')
            self.take = take
            self.cancelled = threading.Event()
            self.error, self.outcome, self.state = None, 'not_attempted', 'transcribing'
            self.thread = threading.Thread(target=self._finish, args=(take, self.cancelled, None, False))
            self.thread.start()
            return self.status()

    def tick(self):
        with self.lock:
            if self.state != 'recording':
                return
            if self.clock() - self.started >= self.maximum_seconds:
                self._cancel(discard=False)
                self.error = 'recording_limit'
            elif not self.capture.running():
                self._cancel(discard=False)
                self.error = 'capture_interrupted'

    def wait(self, seconds=2):
        if self.thread:
            self.thread.join(seconds)
            if self.thread.is_alive():
                raise TimeoutError('Inference did not stop')

    def close(self):
        with self.lock:
            self.closed = True
            self._cancel(discard=False)
        self.wait(3)
        self.engine.close()

class HyprlandDelivery:
    def __init__(self, config, run=None):
        self.config, self.run = config, run or subprocess.run

    def snapshot(self):
        if self.config.get('mode') != 'type':
            return None
        try:
            locked = self.run(['hyprctl', '-j', 'locked'], capture_output=True,
                              text=True, check=True, timeout=2)
            lock_state = json.loads(locked.stdout)
            if not isinstance(lock_state, dict) or lock_state.get('locked') is not False:
                return None
            result = self.run(['hyprctl', '-j', 'activewindow'], capture_output=True,
                              text=True, check=True, timeout=2)
            active = json.loads(result.stdout)
            if (not isinstance(active.get('address'), str) or not active['address'] or
                    not isinstance(active.get('class'), str) or not active['class'] or
                    type(active.get('pid')) is not int or active['pid'] <= 0):
                return None
            return {key: active[key] for key in ('address', 'class', 'pid')}
        except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
            return None

    def submit(self, text, target):
        if (self.config.get('mode') != 'type' or
                self.config.get('allow_unknown_secure_field') is not True or
                not target or target.get('class') not in self.config.get('allowed_classes', [])):
            return 'recover_only'
        # wtype maps these to physical actions (Return, Tab, Escape), not literal text.
        if any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in text):
            return 'unsupported_text'
        if self.snapshot() != target:
            return 'target_changed'
        try:
            self.run(['wtype', '-'], input=text.encode('utf-8'), stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, check=True, timeout=15,
                     env={**os.environ, 'LC_ALL': 'C.UTF-8'})
        except (OSError, subprocess.SubprocessError):
            # The helper could have sent a prefix. Never replay automatically.
            return 'unknown'
        return 'unknown'


def stop_process(process, first=signal.SIGTERM):
    if process is None:
        return
    process.poll()
    for sig, limit in ((first, 1.5), (signal.SIGKILL, .5)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            continue
        if sig == signal.SIGKILL:
            break
        # Stop any descendants even if the group leader exits first.
    process.wait(timeout=.5)


class PipeWireCapture:
    def __init__(self, target=None):
        self.target, self.process, self.path = target, None, None

    def argv(self, path):
        result = ['pw-record', '--rate=16000', '--channels=1', '--format=s16']
        if self.target:
            result.append('--target=' + self.target)
        return result + [str(path)]

    def start(self, path):
        if self.process is not None:
            raise ValueError('Capture already active')
        self.path = path
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        self.process = subprocess.Popen(self.argv(path), stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True)

    def running(self):
        return self.process is not None and self.process.poll() is None

    def stop(self):
        process, self.process = self.process, None
        if process is not None:
            if process.poll() is not None:
                stop_process(process)
                raise ValueError('Capture stopped before release')
            stop_process(process, signal.SIGINT)
            if process.returncode != 0:
                raise ValueError('Capture did not finalize')
        try:
            with wave.open(str(self.path), 'rb') as audio:
                if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 16000, 'NONE'):
                    raise ValueError('Invalid capture format')
                if not 0 < audio.getnframes() <= 16000 * 120:
                    raise ValueError('Capture is empty or exceeds limit')
                if len(audio.readframes(audio.getnframes())) != audio.getnframes() * 2:
                    raise ValueError('Truncated capture')
        except (wave.Error, EOFError) as error:
            raise ValueError('Invalid capture') from error

    def cancel(self):
        process, self.process = self.process, None
        stop_process(process)

class SpeechEngine:
    def __init__(self, settings, *, python=sys.executable, worker=None, request_seconds=30, startup_seconds=120):
        if not isinstance(settings, dict) or not isinstance(settings.get('artifacts'), dict):
            raise ValueError('Invalid speech artifact configuration')
        for item in settings['artifacts'].values():
            if (not isinstance(item, dict) or not isinstance(item.get('path'), str) or
                    not isinstance(item.get('sha256'), str) or
                    not re.fullmatch('[0-9a-f]{64}', item['sha256'])):
                raise ValueError('Invalid speech artifact entry')
        self.settings, self.python = settings, python
        self.script = worker or PROOF / 'worker.py'
        self.request_seconds, self.startup_seconds = request_seconds, startup_seconds
        self.worker = None
        self.lock = threading.Lock()

    def transcribe(self, path, cancelled):
        with self.lock:
            try:
                if self.worker is None:
                    verify_artifacts(self.settings)
                    self.worker = Worker([self.python, str(self.script), 'speech'])
                    remaining = self.worker.send({'configuration': self.settings}, self.startup_seconds, cancelled)
                    ready = self.worker.receive(remaining, cancelled)
                    if ready.get('event') != 'ready':
                        raise ValueError('Speech engine is unavailable')
                identity = uuid.uuid4().hex
                remaining = self.worker.send({'id': identity, 'wav': str(path)}, self.request_seconds, cancelled)
                result = self.worker.receive(remaining, cancelled)
                if result.get('id') != identity or not isinstance(result.get('text'), str):
                    raise ValueError('Invalid engine result')
                return result['text']
            except (OSError, ValueError, KeyError, TypeError, Stopped):
                self.close()
                raise RuntimeError('Speech engine unavailable') from None

    def close(self):
        worker, self.worker = self.worker, None
        if worker:
            worker.close()


def validate_config(value):
    if not isinstance(value, dict) or not isinstance(value.get('engine_config'), str):
        raise ValueError('engine_config is required')
    result = {'maximum_recording_seconds': 60, 'request_seconds': 30,
              'delivery': {'mode': 'recover'}, **value}
    for field, minimum, maximum in (('maximum_recording_seconds', 1, 120), ('request_seconds', 1, 120)):
        number = result[field]
        if type(number) not in (int, float) or not math.isfinite(number) or not minimum <= number <= maximum:
            raise ValueError('Invalid finite ' + field)
    delivery = result['delivery']
    if not isinstance(delivery, dict) or delivery.get('mode') not in ('recover', 'type'):
        raise ValueError('delivery.mode must be recover or type')
    if delivery.get('mode') == 'type':
        classes = delivery.get('allowed_classes')
        if (not isinstance(classes, list) or not classes or
                any(not isinstance(item, str) or not item or '*' in item for item in classes)):
            raise ValueError('Type delivery requires exact allowed_classes')
    for name in ('python', 'capture_target'):
        if name in result and (not isinstance(result[name], str) or not result[name] or '\0' in result[name]):
            raise ValueError('Invalid ' + name)
    return result


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


def serve(path, session, stopped, *, lifetime_seconds=43200):
    path = Path(path)
    # The lock owns this one runtime socket, including cleanup after an interrupted session.
    with open(str(path) + '.lock', 'a') as ownership:
        os.chmod(ownership.name, 0o600)
        fcntl.flock(ownership, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if path.exists():
            info = path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError('Refusing to replace runtime path')
            path.unlink()
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(path))
            os.chmod(path, 0o600)
            server.listen(4)
            server.settimeout(.1)
            end = time.monotonic() + lifetime_seconds
            try:
                while not stopped.is_set() and time.monotonic() < end:
                    session.tick()
                    try:
                        connection, _ = server.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(.2)
                        try:
                            message = read_message(connection)
                            if not isinstance(message, dict):
                                raise ValueError('Invalid command')
                            action = message.get('action')
                            if action == 'shutdown':
                                stopped.set()
                                result = {'state': 'stopping'}
                            elif action == 'transcribe':
                                result = session.recover_audio(message.get('id'))
                            elif action in ('start', 'stop', 'toggle', 'cancel', 'status'):
                                result = session.command(action)
                            else:
                                raise ValueError('Unknown action')
                        except (OSError, ValueError, TypeError):
                            result = {'error': 'invalid_command'}
                        try:
                            connection.sendall(json.dumps(result).encode() + b'\n')
                        except OSError:
                            pass
            finally:
                path.unlink(missing_ok=True)


def request(path, action, identity=None):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2.5)
        connection.connect(str(path))
        connection.sendall(json.dumps({'action': action, 'id': identity}).encode() + b'\n')
        return read_message(connection, maximum=16384)


def recovery_path(root, identity):
    if not isinstance(identity, str) or not re.fullmatch('[0-9a-f]{32}', identity):
        raise ValueError('Invalid recovery ID')
    path = Path(root) / identity
    if path.is_symlink() or not path.is_dir():
        raise ValueError('Recovery is unavailable')
    return path


def recovery_list(root):
    root = Path(root)
    if not root.exists():
        return []
    return [{'id': path.name, 'transcript': (path / 'transcript.txt').is_file(),
             'audio': (path / 'recording.wav').is_file()}
            for path in sorted(root.iterdir())
            if re.fullmatch('[0-9a-f]{32}', path.name) and path.is_dir() and not path.is_symlink()]


def recovery_result(root, identity):
    return (recovery_path(root, identity) / 'transcript.txt').read_text(encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home() / '.config/mouthtype/linux.json')
    runtime_base = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid())))
    state_base = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state'))
    parser.add_argument('--runtime', type=Path, default=runtime_base / 'mouthtype')
    parser.add_argument('--recovery', type=Path, default=state_base / 'mouthtype/recovery')
    commands = parser.add_subparsers(dest='action', required=True)
    service = commands.add_parser('serve')
    service.add_argument('--lifetime-seconds', type=float, default=43200)
    for action in ('start', 'stop', 'toggle', 'cancel', 'status', 'shutdown', 'list'):
        commands.add_parser(action)
    for action in ('recover', 'transcribe', 'forget'):
        commands.add_parser(action).add_argument('id')
    args = parser.parse_args()
    path = args.runtime / 'session.sock'
    try:
        if args.action == 'list':
            print(json.dumps(recovery_list(args.recovery)))
            return 0
        if args.action == 'recover':
            sys.stdout.write(recovery_result(args.recovery, args.id))
            return 0
        if args.action == 'forget':
            take = recovery_path(args.recovery, args.id)
            if path.exists():
                status = request(path, 'status')
                if status.get('recovery') == args.id and status.get('state') != 'idle':
                    raise ValueError('Recovery is in use')
            for name in ('recording.wav', 'transcript.txt'):
                (take / name).unlink(missing_ok=True)
            take.rmdir()
            return 0
        if args.action != 'serve':
            print(json.dumps(request(path, args.action, getattr(args, 'id', None))))
            return 0
        if sys.platform != 'linux':
            raise ValueError('The recording service requires Linux')
        if not math.isfinite(args.lifetime_seconds) or not 1 <= args.lifetime_seconds <= 86400:
            raise ValueError('Session lifetime must be between one second and 24 hours')
        config = validate_config(json.loads(args.config.read_text()))
        engine_path = Path(config['engine_config']).expanduser()
        if not engine_path.is_absolute():
            engine_path = args.config.resolve().parent / engine_path
        settings = json.loads(engine_path.read_text())['engines']['speech']
        args.runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = args.runtime.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Runtime directory must be owned by you with mode 0700')
        engine = SpeechEngine(settings, python=config.get('python', sys.executable),
                              request_seconds=config['request_seconds'])
        session = Session(PipeWireCapture(config.get('capture_target')), engine,
                          HyprlandDelivery(config['delivery']), args.recovery,
                          maximum_seconds=config['maximum_recording_seconds'])
        stopped = threading.Event()
        for event in (signal.SIGINT, signal.SIGTERM):
            signal.signal(event, lambda *_: stopped.set())
        try:
            serve(path, session, stopped, lifetime_seconds=args.lifetime_seconds)
        finally:
            session.close()
        return 0
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        # Config paths, model errors and transcripts never go into routine diagnostics.
        print(json.dumps({'error': 'unavailable', 'error_class': type(error).__name__}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
