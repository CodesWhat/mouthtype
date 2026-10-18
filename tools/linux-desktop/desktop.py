"""Mouthtype Linux session service and compositor command client."""

import argparse
import fcntl
import json
import math
import os
import re
import selectors
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
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(PROOF))
from proof import Stopped, Worker, verify_artifacts
from spellings import load_spellings
from phrases import load_phrases, PhraseContextUnavailable
from cleanup import BasicCleanup
import imports
from imports import FileError, FileTranscription
import smart

INTERFACE = 1
CAPABILITIES = {
    'interface': INTERFACE,
    'client': 'linux-development',
    'features': {
        'dictation': True, 'recovery': True, 'doctor': True,
        'cleanup_levels': ['off', 'basic', 'fast', 'thorough'],
        'delivery_modes': ['recover', 'type', 'paste'],
        'file_transcription': {'formats': list(imports.FORMATS), 'extensions': list(imports.EXTENSIONS),
                               'maximum_seconds': imports.MAXIMUM_SECONDS,
                               'maximum_bytes': imports.MAXIMUM_SOURCE_BYTES},
        'state_stream': True, 'level_meter': True,
        'ai_cleanup': {'levels': ['fast', 'thorough'], 'runtime': 'llama.cpp CPU server', 'setup': 'setup_cleanup.py'},
        'pill': 'frontend', 'typography': 'frontend', 'live_words': False,
        'secure_field_detection': False, 'delivery_verification': False,
    },
}


def private_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(data)
    except BaseException:
        # This invocation created the file. Never leave a partial result marked complete.
        path.unlink(missing_ok=True)
        raise


def level_db(data):
    """dBFS of little-endian PCM16 bytes, floored at -120."""
    count = len(data) // 2
    if count == 0:
        return -120.0
    from array import array
    samples = array('h')
    samples.frombytes(data[:count * 2])
    if sys.byteorder != 'little':
        samples.byteswap()
    total = 0
    for sample in samples:
        total += sample * sample
    rms = math.sqrt(total / count) / 32768
    if rms <= 0:
        return -120.0
    return round(max(-120.0, 20 * math.log10(rms)), 1)


class Session:
    def __init__(self, capture, engine, delivery, recovery, *, maximum_seconds=60, clock=None, feedback=None,
                 dictionary=None, phrases=None, phrase_clipboard=False, clipboard=None, cleanup='off',
                 cleanup_engine=None):
        self.capture, self.engine, self.delivery = capture, engine, delivery
        self.cleanup_engine = cleanup_engine
        self.cleanup_outcome, self.cleanup_ms = None, None
        self.feedback = feedback
        self.dictionary = dictionary
        self.phrases = phrases
        self.cleanup = cleanup
        self.phrase_clipboard = phrase_clipboard
        self.clipboard = clipboard or read_phrase_clipboard
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
        self.discard_on_cancel = False
        self.closed = False

    def status(self):
        return {'state': self.state, 'error': self.error, 'delivery': self.outcome,
                'recovery': self.take.name if self.take else None,
                'context': 'unsupported', 'secure_field_detection': 'unsupported',
                'delivery_verified': False,
                'cleanup': {'level': self.cleanup, 'last_outcome': self.cleanup_outcome, 'last_ms': self.cleanup_ms,
                            'model': self.cleanup_engine.status() if self.cleanup_engine is not None else None},
                'feedback': getattr(self.feedback, 'status', 'unavailable') if self.feedback else 'disabled'}

    def _notify(self, state):
        if self.feedback:
            try:
                self.feedback.notify(state)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                pass

    def command(self, action, *, admit_before=None):
        with self.lock:
            if action == 'status':
                return self.status()
            if self.closed:
                raise ValueError('Session is closed')
            if action == 'toggle':
                action = 'stop' if self.state == 'recording' else 'start'
            if action == 'start' and self.state == 'idle':
                if admit_before is not None and time.monotonic() >= admit_before:
                    self.error = 'command_expired'
                    return self.status()
                try:
                    spellings = load_spellings(self.dictionary)
                except (OSError, ValueError):
                    self.error = 'dictionary_unavailable'
                    self._notify('error')
                    return self.status()
                try:
                    phrases = load_phrases(self.phrases, clipboard=self.clipboard if self.phrase_clipboard else None)
                except PhraseContextUnavailable:
                    self.error = 'phrase_context_unavailable'
                    self._notify('error')
                    return self.status()
                except (OSError, ValueError, subprocess.SubprocessError):
                    self.error = 'phrases_unavailable'
                    self._notify('error')
                    return self.status()
                try:
                    cleanup = BasicCleanup('basic' if self.cleanup in ('fast', 'thorough') else self.cleanup)
                except ValueError:
                    self.error = 'cleanup_unavailable'
                    self._notify('error')
                    return self.status()
                target = self.delivery.snapshot()
                if admit_before is not None and time.monotonic() >= admit_before:
                    self.error = 'command_expired'
                    return self.status()
                if len(list(self.recovery.iterdir())) >= 50:
                    self.error = 'recovery_full'
                    return self.status()
                self.take = self.recovery / uuid.uuid4().hex
                self.take.mkdir(mode=0o700)
                self.discard_on_cancel = True
                self.target = target
                self.spellings = spellings
                self.phrase_rules = phrases
                self.cleanup_rules = cleanup
                self.cancelled = threading.Event()
                self.error, self.outcome = None, 'not_attempted'
                try:
                    self.capture.start(self.take / 'recording.wav')
                except (OSError, ValueError, subprocess.SubprocessError):
                    self.capture.cancel()
                    try:
                        audio = self.take / 'recording.wav'
                        if audio.exists() and audio.stat().st_size == 0:
                            audio.unlink()
                        self.take.rmdir()
                    except OSError:
                        pass
                    else:
                        self.take = None
                        self.discard_on_cancel = False
                    self.error = 'capture_unavailable'
                    self._notify('error')
                    return self.status()
                self.started, self.state = self.clock(), 'recording'
                self._notify('recording')
            elif action == 'stop' and self.state == 'recording':
                try:
                    self.capture.stop()
                except (OSError, ValueError, subprocess.SubprocessError):
                    self.capture.cancel()
                    self.state, self.error = 'idle', 'capture_interrupted'
                    self._notify('error')
                    return self.status()
                self.state = 'transcribing'
                self._notify('transcribing')
                self.thread = threading.Thread(target=self._finish,
                                               args=(self.take, self.cancelled, self.target, self.spellings, self.phrase_rules, self.cleanup_rules))
                self.thread.start()
            elif action == 'cancel':
                if self.state != 'idle':
                    self._cancel(discard=True)
                    self._notify('cancelled')
            elif action not in ('start', 'stop'):
                raise ValueError('Unknown action')
            return self.status()

    def _cancel(self, *, discard):
        self.cancelled.set()
        if self.state == 'recording':
            self.capture.cancel()
        self.state = 'cancelling' if self.state in ('transcribing', 'cancelling') and self.thread and self.thread.is_alive() else 'idle'
        self.outcome = 'not_attempted'
        if discard and self.discard_on_cancel and self.take:
            # Only the current recording is disposable. A completed transcript remains recoverable.
            (self.take / 'recording.wav').unlink(missing_ok=True)
            if not (self.take / 'transcript.txt').exists():
                (self.take / 'raw-recognition.txt').unlink(missing_ok=True)
            try:
                self.take.rmdir()
            except OSError:
                pass

    def _finish(self, take, cancelled, target, spellings, phrases, cleanup, allow_delivery=True):
        try:
            raw_path = take / 'raw-recognition.txt'
            raw = raw_path.read_bytes().decode('utf-8') if raw_path.exists() else self.engine.transcribe(take / 'recording.wav', cancelled)
            if not isinstance(raw, str):
                raise ValueError('Invalid transcript')
            with self.lock:
                if cancelled.is_set() or self.closed:
                    return
                if not raw_path.exists():
                    private_write(raw_path, raw)
            basic = cleanup.apply(raw)
            outcome, milliseconds = self._model_cleanup(basic, cancelled)
            text = basic if outcome is None or not isinstance(outcome[1], str) else outcome[1]
            text = phrases.apply(spellings.apply(text))
            with self.lock:
                if cancelled.is_set() or self.closed:
                    return
                private_write(take / 'transcript.txt', text)
                if outcome is not None:
                    self.cleanup_outcome, self.cleanup_ms = outcome[0], milliseconds
                    private_write(take / 'cleanup.json', json.dumps({'level': self.cleanup, 'outcome': outcome[0],
                                                                      'milliseconds': milliseconds, 'reason': outcome[2]}))
                self.outcome = 'empty' if not text else 'recover_only' if not allow_delivery else 'target_changed'
                if allow_delivery and text and target == self.delivery.snapshot():
                    self.outcome = self.delivery.submit(text, target)
                # Audio remains available after delivery uncertainty; success is never inferred.
                self.state = 'idle'
                self._notify('delivered' if self.outcome == 'unknown' else 'saved' if text else 'empty')
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            with self.lock:
                if not cancelled.is_set() and not self.closed:
                    self.error, self.state = 'transcription_failed', 'idle'
                    self._notify('error')
        finally:
            with self.lock:
                if cancelled.is_set() and self.cancelled is cancelled and self.state == 'cancelling':
                    self.state = 'idle'

    def _model_cleanup(self, basic, cancelled):
        """Run the resident model on the deterministic text within its budget. Any trouble keeps the basic text."""
        if self.cleanup not in ('fast', 'thorough') or self.cleanup_engine is None:
            return None, None
        if not smart.eligible(basic):
            return ('skipped', None, None), 0
        started = time.monotonic()
        seconds = smart.budget_seconds(self.cleanup, smart.word_count(basic))
        try:
            model = self.cleanup_engine.clean(basic, cancelled, seconds=seconds)
        except (OSError, ValueError, RuntimeError, Stopped, subprocess.SubprocessError) as error:
            return ('failed', None, type(error).__name__), int((time.monotonic() - started) * 1000)
        elapsed = int((time.monotonic() - started) * 1000)
        if model is None:
            return ('timeout', None, None), elapsed
        accepted, reason = smart.check(basic, model)
        if accepted is None:
            return ('guard-rejected', None, reason), elapsed
        return ('ok', accepted, None), elapsed

    def recover_audio(self, identity):
        with self.lock:
            if self.closed or self.state != 'idle':
                return self.status()
            take = recovery_path(self.recovery, identity)
            if (take / 'transcript.txt').exists():
                return self.status()
            if not (take / 'recording.wav').is_file():
                raise ValueError('No saved audio')
            try:
                spellings = load_spellings(self.dictionary)
            except (OSError, ValueError):
                self.error = 'dictionary_unavailable'
                self._notify('error')
                return self.status()
            try:
                phrases = load_phrases(self.phrases, clipboard=self.clipboard if self.phrase_clipboard else None)
            except PhraseContextUnavailable:
                self.error = 'phrase_context_unavailable'
                self._notify('error')
                return self.status()
            except (OSError, ValueError, subprocess.SubprocessError):
                self.error = 'phrases_unavailable'
                self._notify('error')
                return self.status()
            try:
                cleanup = BasicCleanup('basic' if self.cleanup in ('fast', 'thorough') else self.cleanup)
            except ValueError:
                self.error = 'cleanup_unavailable'
                self._notify('error')
                return self.status()
            self.take = take
            self.discard_on_cancel = False
            self.cancelled = threading.Event()
            self.error, self.outcome, self.state = None, 'not_attempted', 'transcribing'
            self._notify('transcribing')
            self.thread = threading.Thread(target=self._finish, args=(take, self.cancelled, None, spellings, phrases, cleanup, False))
            self.thread.start()
            return self.status()

    def level(self):
        """Coarse microphone level in dBFS from the newest 100 ms of the growing take, or None."""
        with self.lock:
            if self.state != 'recording' or not self.take:
                return None
            path = self.take / 'recording.wav'
        try:
            size = path.stat().st_size
            window = 3200
            if size < 44 + window:
                return None
            with open(path, 'rb') as audio:
                audio.seek(size - window)
                data = audio.read(window)
        except OSError:
            return None
        return level_db(data)

    def elapsed(self):
        with self.lock:
            if self.state != 'recording':
                return None
            return max(0.0, self.clock() - self.started)

    def tick(self):
        with self.lock:
            if self.state != 'recording':
                return
            if self.clock() - self.started >= self.maximum_seconds:
                self._cancel(discard=False)
                self.error = 'recording_limit'
                self._notify('error')
            elif not self.capture.running():
                self._cancel(discard=False)
                self.error = 'capture_interrupted'
                self._notify('error')

    def wait(self, seconds=2):
        if self.thread:
            self.thread.join(seconds)
            if self.thread.is_alive():
                raise TimeoutError('Inference did not stop')

    def close(self):
        with self.lock:
            active = self.state != 'idle'
            self.closed = True
            self._cancel(discard=False)
            if active:
                self._notify('cancelled')
        self.wait(3)
        self.engine.close()

class HyprlandDelivery:
    def __init__(self, config, run=None):
        self.config, self.run = config, run or subprocess.run

    def snapshot(self):
        if self.config.get('mode') not in ('type', 'paste'):
            return None
        try:
            locked = self.run(['hyprctl', '-j', 'locked'], capture_output=True,
                              text=True, check=True, timeout=.5)
            lock_state = json.loads(locked.stdout)
            if not isinstance(lock_state, dict) or lock_state.get('locked') is not False:
                return None
            result = self.run(['hyprctl', '-j', 'activewindow'], capture_output=True,
                              text=True, check=True, timeout=.5)
            active = json.loads(result.stdout)
            if (not isinstance(active.get('address'), str) or not active['address'] or
                    not isinstance(active.get('class'), str) or not active['class'] or
                    type(active.get('pid')) is not int or active['pid'] <= 0):
                return None
            return {key: active[key] for key in ('address', 'class', 'pid')}
        except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
            return None

    # Terminals paste with Ctrl+Shift+V, and a pasted line break runs a command there.
    TERMINAL_CLASSES = ('Alacritty', 'kitty', 'foot', 'footclient', 'com.mitchellh.ghostty', 'org.wezfurlong.wezterm',
                        'konsole', 'org.kde.konsole', 'org.gnome.Terminal', 'gnome-terminal-server', 'xterm', 'st',
                        'com.github.contour-terminal.contour', 'Terminal', 'tilix', 'com.gexperts.Tilix',
                        'org.omarchy.agent')
    # A terminal launched with a custom window class is still a terminal; its process name says so.
    TERMINAL_EXECUTABLES = ('ghostty', 'alacritty', 'kitty', 'foot', 'footclient', 'wezterm-gui', 'wezterm', 'konsole',
                            'gnome-terminal-server', 'gnome-terminal', 'xterm', 'st', 'tilix', 'contour', 'rio',
                            'xfce4-terminal', 'urxvt', 'terminator', 'ptyxis', 'wayst', 'blackbox', 'tabby')

    def process_name(self, pid):
        try:
            if type(pid) is not int or pid <= 0:
                return None
            return Path('/proc/%d/comm' % pid).read_text().strip()
        except (OSError, ValueError):
            return None

    def allowed(self, target):
        if (self.config.get('mode') not in ('type', 'paste') or
                self.config.get('allow_unknown_secure_field') is not True or not target):
            return False
        if self.config.get('any_window') is True:
            return True
        return target.get('class') in self.config.get('allowed_classes', [])

    def is_terminal(self, target):
        classes = self.config.get('terminal_classes', list(self.TERMINAL_CLASSES))
        if target.get('class') in classes:
            return True
        executables = self.config.get('terminal_executables', list(self.TERMINAL_EXECUTABLES))
        return self.process_name(target.get('pid')) in executables

    def submit(self, text, target):
        if not self.allowed(target):
            return 'recover_only'
        if self.config.get('mode') == 'type':
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
        return self.paste(text, target)

    def paste(self, text, target):
        """Clipboard plus a paste chord. Line breaks and tabs travel as text; other controls are refused."""
        if any((ord(char) < 32 and char not in '\n\t') or 127 <= ord(char) <= 159 for char in text):
            return 'unsupported_text'
        terminal = self.is_terminal(target)
        if terminal and '\n' in text.strip() and self.config.get('allow_terminal_multiline') is not True:
            return 'unsupported_text'
        if self.snapshot() != target:
            return 'target_changed'
        previous = None
        if self.config.get('restore_clipboard', True):
            try:
                previous = self.clipboard()
            except (OSError, ValueError, PhraseContextUnavailable, subprocess.SubprocessError):
                previous = None
        try:
            self.run(['wl-copy', '--type', 'text/plain;charset=utf-8'], input=text.encode('utf-8'),
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=5)
            # The clipboard owner forks; the target only sees the new offer once it is live.
            if not self.wait_for_clipboard(text):
                return 'unknown'
            if self.snapshot() != target:
                return 'target_changed'
            self.send_paste_chord(target, terminal)
        except (OSError, subprocess.SubprocessError):
            return 'unknown'
        finally:
            if previous is not None:
                self.schedule_restore(previous, text)
        return 'unknown'

    settle_seconds = 1.5
    restore_thread = None

    def wait_for_clipboard(self, text):
        end = time.monotonic() + self.settle_seconds
        while True:
            try:
                if self.clipboard() == text:
                    return True
            except (OSError, ValueError, PhraseContextUnavailable, subprocess.SubprocessError):
                pass
            if time.monotonic() >= end:
                return False
            time.sleep(.05)

    def send_paste_chord(self, target, terminal):
        """Hyprland delivers the chord to the captured window itself; wtype is the fallback for other compositors."""
        mods = 'CTRL SHIFT' if terminal else 'CTRL'
        window = 'address:' + str(target.get('address', ''))
        attempts = (
            ['hyprctl', 'dispatch', 'hl.dsp.send_shortcut({mods=%s, key="v", window=%s})' % (json.dumps(mods), json.dumps(window))],
            ['hyprctl', 'dispatch', 'sendshortcut', mods.replace(' ', '+') + ',v,' + window],
        )
        for argv in attempts:
            try:
                result = self.run(argv, capture_output=True, text=True, check=False, timeout=5)
            except (OSError, subprocess.SubprocessError):
                continue
            output = (getattr(result, 'stdout', '') or '') + (getattr(result, 'stderr', '') or '')
            if getattr(result, 'returncode', 1) == 0 and 'ok' in output and 'error' not in output.lower():
                return
        chord = (['wtype', '-M', 'ctrl', '-M', 'shift', '-k', 'v', '-m', 'shift', '-m', 'ctrl'] if terminal
                 else ['wtype', '-M', 'ctrl', '-k', 'v', '-m', 'ctrl'])
        self.run(chord, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=15)

    def clipboard(self):
        return read_phrase_clipboard()

    def schedule_restore(self, previous, ours, *, delay=.6):
        """Put the earlier text clipboard back once the target has had time to read ours, unless something newer owns it."""
        def restore():
            time.sleep(delay)
            try:
                if self.clipboard() != ours:
                    return
                self.run(['wl-copy', '--type', 'text/plain;charset=utf-8'], input=previous.encode('utf-8'),
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=5)
            except (OSError, ValueError, PhraseContextUnavailable, subprocess.SubprocessError):
                pass
        self.restore_thread = threading.Thread(target=restore, daemon=True)
        self.restore_thread.start()


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


def read_phrase_clipboard(command=None, *, seconds=1, maximum=1024 * 1024, env=None):
    process = subprocess.Popen(command or ['wl-paste', '--no-newline', '--type', 'text'],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True, env=env)
    try:
        end = time.monotonic() + seconds
        output = bytearray()
        os.set_blocking(process.stdout.fileno(), False)
        with selectors.DefaultSelector() as reader:
            reader.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = end - time.monotonic()
                if remaining <= 0 or not reader.select(remaining):
                    raise PhraseContextUnavailable('Clipboard phrase context timed out')
                data = os.read(process.stdout.fileno(), min(65536, maximum + 1 - len(output)))
                if not data:
                    break
                output.extend(data)
                if len(output) > maximum:
                    raise PhraseContextUnavailable('Clipboard phrase context exceeds its limit')
        if process.wait(timeout=max(0, end - time.monotonic())) != 0:
            raise PhraseContextUnavailable('Clipboard phrase context is unavailable')
        return output.decode('utf-8')
    finally:
        process.stdout.close()
        stop_process(process)


class PipeWireCapture:
    def __init__(self, target=None, *, errors=subprocess.DEVNULL):
        self.target, self.process, self.path = target, None, None
        self.errors = errors

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
                                        stdout=subprocess.DEVNULL, stderr=self.errors,
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
            # Upstream pw-record closes the WAV on SIGINT but returns1 unless playback drained.
            if process.returncode not in (0, 1):
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

    def transcribe(self, path, cancelled, *, seconds=None):
        seconds = self.request_seconds if seconds is None else seconds
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
                remaining = self.worker.send({'id': identity, 'wav': str(path)}, seconds, cancelled)
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


class CleanupEngine:
    """A resident llama.cpp server behind the proof worker, loaded once and stopped with the service."""

    def __init__(self, settings, *, python=sys.executable, worker=None, startup_seconds=300):
        if (not isinstance(settings, dict) or not isinstance(settings.get('artifacts'), dict) or
                not isinstance(settings.get('server'), str) or settings.get('prompt', 's1') not in ('s1', 'shared')):
            raise ValueError('Invalid cleanup engine configuration')
        for item in settings['artifacts'].values():
            if (not isinstance(item, dict) or not isinstance(item.get('path'), str) or
                    not isinstance(item.get('sha256'), str) or not re.fullmatch('[0-9a-f]{64}', item['sha256'])):
                raise ValueError('Invalid cleanup artifact entry')
        self.settings, self.python = settings, python
        self.script = worker or PROOF / 'worker.py'
        self.startup_seconds = startup_seconds
        self.worker = None
        self.lock = threading.Lock()
        present = all(Path(item['path']).is_file() for item in settings['artifacts'].values())
        self.state = 'idle' if present else 'absent'
        self.error = None
        self.load_ms = None

    def status(self):
        return {'state': self.state, 'error': self.error, 'load_ms': self.load_ms,
                'prompt': self.settings.get('prompt', 's1')}

    def _ensure_loaded(self, cancelled):
        if self.worker is not None:
            return
        self.state = 'loading'
        started = time.monotonic()
        verify_artifacts(self.settings)
        self.worker = Worker([self.python, str(self.script), 'cleanup'])
        remaining = self.worker.send({'configuration': {**self.settings, 'startup_seconds': self.startup_seconds}},
                                     self.startup_seconds, cancelled)
        ready = self.worker.receive(remaining, cancelled)
        if ready.get('event') != 'ready':
            raise ValueError('Cleanup engine is unavailable')
        self.load_ms = int((time.monotonic() - started) * 1000)
        self.state = 'ready'
        self.error = None

    def warm(self):
        """Load in the background so the first take does not pay the cold start."""
        def run():
            with self.lock:
                try:
                    self._ensure_loaded(threading.Event())
                    self._prime()
                except (OSError, ValueError, KeyError, TypeError, Stopped) as error:
                    self._fail(error)
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread

    def _prime(self):
        """One short request so the server caches the system prompt; the first real take then pays only for its words."""
        try:
            identity = uuid.uuid4().hex
            remaining = self.worker.send({'id': identity, 'input': 'Warm up, please.', 'deadline_seconds': 60},
                                         60, threading.Event())
            self.worker.receive(remaining, threading.Event())
        except (OSError, ValueError, KeyError, TypeError, Stopped):
            pass

    def _fail(self, error):
        self.state, self.error = 'failed', type(error).__name__
        worker, self.worker = self.worker, None
        if worker:
            worker.close()

    def clean(self, text, cancelled, *, seconds, controls=None):
        """The model's text, or None when the request timed out while the server stayed warm."""
        with self.lock:
            try:
                self._ensure_loaded(cancelled)
                identity = uuid.uuid4().hex
                request = {'id': identity, 'input': text, 'deadline_seconds': seconds}
                if controls:
                    request['controls'] = controls
                remaining = self.worker.send(request, seconds + 5, cancelled)
                result = self.worker.receive(remaining, cancelled)
                if result.get('id') != identity:
                    raise ValueError('Invalid cleanup result')
                if result.get('event') == 'timeout':
                    return None
                if result.get('event') == 'error' or not isinstance(result.get('text'), str):
                    raise ValueError('Cleanup engine error')
                return result['text']
            except (OSError, ValueError, KeyError, TypeError, Stopped) as error:
                self._fail(error)
                if self.state == 'failed' and Path(self.settings['artifacts']['model']['path']).is_file():
                    # A cancelled or crashed request reloads on the next take.
                    self.state = 'idle'
                raise RuntimeError('Cleanup engine unavailable') from None

    def close(self):
        with self.lock:
            worker, self.worker = self.worker, None
            if worker:
                worker.close()
            if self.state in ('ready', 'loading'):
                self.state = 'idle'


def validate_config(value):
    if not isinstance(value, dict) or not isinstance(value.get('engine_config'), str):
        raise ValueError('engine_config is required')
    result = {'maximum_recording_seconds': 60, 'request_seconds': 30,
              'delivery': {'mode': 'recover'}, 'notifications': True, 'cleanup': 'off', **value}
    if type(result['notifications']) is not bool:
        raise ValueError('notifications must be true or false')
    for field, minimum, maximum in (('maximum_recording_seconds', 1, 120), ('request_seconds', 1, 120)):
        number = result[field]
        if type(number) not in (int, float) or not math.isfinite(number) or not minimum <= number <= maximum:
            raise ValueError('Invalid finite ' + field)
    delivery = result['delivery']
    if not isinstance(delivery, dict) or delivery.get('mode') not in ('recover', 'type', 'paste'):
        raise ValueError('delivery.mode must be recover, type or paste')
    if delivery.get('mode') in ('type', 'paste'):
        for flag in ('any_window', 'restore_clipboard', 'allow_terminal_multiline', 'allow_unknown_secure_field'):
            if flag in delivery and type(delivery[flag]) is not bool:
                raise ValueError('delivery.' + flag + ' must be true or false')
        classes = delivery.get('allowed_classes')
        if delivery.get('any_window') is not True and (
                not isinstance(classes, list) or not classes or
                any(not isinstance(item, str) or not item or '*' in item for item in classes)):
            raise ValueError('Automatic delivery requires exact allowed_classes or any_window')
        if 'allowed_classes' in delivery and (not isinstance(classes, list) or
                                              any(not isinstance(item, str) or not item for item in classes)):
            raise ValueError('allowed_classes must be a list of window classes')
        for field in ('terminal_classes', 'terminal_executables'):
            terminals = delivery.get(field)
            if terminals is not None and (not isinstance(terminals, list) or any(not isinstance(item, str) for item in terminals)):
                raise ValueError(field + ' must be a list of names')
    for name in ('python', 'capture_target', 'dictionary', 'phrases'):
        if name in result and (not isinstance(result[name], str) or not result[name] or '\0' in result[name]):
            raise ValueError('Invalid ' + name)
    if not isinstance(result['cleanup'], str) or result['cleanup'] not in ('off', 'basic', 'fast', 'thorough'):
        raise ValueError('cleanup must be off, basic, fast or thorough')
    if result['cleanup'] in ('fast', 'thorough'):
        engine = result.get('cleanup_engine')
        if not isinstance(engine, str) or not engine or '\0' in engine:
            raise ValueError('Model cleanup requires a cleanup_engine configuration path')
    if type(result.get('phrase_clipboard', False)) is not bool:
        raise ValueError('phrase_clipboard must be true or false')
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


def serve(path, session, stopped, *, lifetime_seconds=43200, files=None):
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
            watchers = []
            last_snapshot = None
            try:
                while not stopped.is_set() and time.monotonic() < end:
                    session.tick()
                    if watchers:
                        snapshot = state_snapshot(session, files)
                        if snapshot != last_snapshot or snapshot.get('level') is not None:
                            last_snapshot = snapshot
                            broadcast(watchers, snapshot)
                        else:
                            prune_watchers(watchers)
                    server.settimeout(.05 if watchers and session.state == 'recording' else .1)
                    try:
                        connection, _ = server.accept()
                    except socket.timeout:
                        continue
                    keep = False
                    try:
                        connection.settimeout(.2)
                        try:
                            message = read_message(connection)
                            if not isinstance(message, dict):
                                raise ValueError('Invalid command')
                            action = message.get('action')
                            if action == 'shutdown':
                                stopped.set()
                                result = {'state': 'stopping'}
                            elif action == 'watch':
                                if len(watchers) >= 8:
                                    raise ValueError('Too many watchers')
                                result = state_snapshot(session, files)
                                keep = True
                            elif action == 'import':
                                if files is None:
                                    raise ValueError('File transcription is unavailable')
                                result = files.start(message.get('source'), session_busy=session.state != 'idle')
                            elif action in ('import-status', 'import-cancel', 'import-forget'):
                                if files is None:
                                    raise ValueError('File transcription is unavailable')
                                result = (files.status() if action == 'import-status' else
                                          files.cancel() if action == 'import-cancel' else files.forget())
                            elif action == 'transcribe':
                                if files is not None and files.active():
                                    result = {**session.status(), 'error': 'file_import_active'}
                                else:
                                    result = session.recover_audio(message.get('id'))
                            elif action in ('start', 'stop', 'toggle', 'cancel', 'status'):
                                admission = message.get('admit_before')
                                if action in ('start', 'toggle') and (
                                        type(admission) not in (int, float) or not math.isfinite(admission)):
                                    raise ValueError('Recording admission deadline is required')
                                if action in ('start', 'toggle') and files is not None and files.active() and session.state == 'idle':
                                    # A file job owns the speech engine; a microphone take would wait on it.
                                    result = {**session.status(), 'error': 'file_import_active'}
                                else:
                                    result = session.command(action, admit_before=admission)
                                if action == 'status':
                                    result['file_import'] = files.status() if files is not None else None
                            else:
                                raise ValueError('Unknown action')
                        except (OSError, ValueError, TypeError):
                            result = {'error': 'invalid_command'}
                            keep = False
                        try:
                            connection.sendall(json.dumps(result).encode() + b'\n')
                        except OSError:
                            keep = False
                        if keep:
                            connection.setblocking(False)
                            watchers.append(connection)
                            last_snapshot = result
                    finally:
                        if not keep:
                            connection.close()
            finally:
                for watcher in watchers:
                    try:
                        watcher.sendall(json.dumps({'event': 'stopping'}).encode() + b'\n')
                    except OSError:
                        pass
                    watcher.close()
                path.unlink(missing_ok=True)


def state_snapshot(session, files=None):
    """Text-free state for live frontends: session state, outcome, elapsed time, coarse level."""
    status = session.status()
    return {'event': 'state', 'state': status['state'], 'error': status['error'], 'delivery': status['delivery'],
            'recovery': status['recovery'], 'elapsed': session.elapsed(), 'level': session.level(),
            'file_import': files.status()['state'] if files is not None else None}


def prune_watchers(watchers):
    for watcher in list(watchers):
        try:
            if watcher.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b'':
                raise OSError('closed')
        except BlockingIOError:
            continue
        except OSError:
            watchers.remove(watcher)
            watcher.close()


def broadcast(watchers, snapshot):
    line = json.dumps(snapshot).encode() + b'\n'
    for watcher in list(watchers):
        try:
            watcher.sendall(line)
        except OSError:
            watchers.remove(watcher)
            watcher.close()


def watch(path, output, *, retry=False, stopped=None, interval=1.0):
    """Print one JSON line per state change until the service exits; with retry, keep reconnecting."""
    stopped = stopped or threading.Event()
    announced = False
    while not stopped.is_set():
        try:
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(2.5)
                connection.connect(str(path))
                connection.sendall(json.dumps({'action': 'watch'}).encode() + b'\n')
                connection.settimeout(.5)
                buffer = b''
                announced = False
                while not stopped.is_set():
                    try:
                        chunk = connection.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        break
                    buffer += chunk
                    if len(buffer) > 1024 * 1024:
                        raise ValueError('Watch stream exceeds its limit')
                    while b'\n' in buffer:
                        line, buffer = buffer.split(b'\n', 1)
                        output.write(line.decode('utf-8') + '\n')
                        output.flush()
        except (OSError, ValueError):
            pass
        if not announced:
            output.write(json.dumps({'event': 'disconnected'}) + '\n')
            output.flush()
            announced = True
        if not retry:
            return 0
        stopped.wait(interval)
    return 0


def request(path, action, identity=None, **fields):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(2.5)
        connection.connect(str(path))
        connection.sendall(json.dumps({'action': action, 'id': identity,
                                       'admit_before': time.monotonic() + 1.5, **fields}).encode() + b'\n')
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


def recovery_result(root, identity, *, raw=False):
    return (recovery_path(root, identity) / ('raw-recognition.txt' if raw else 'transcript.txt')).read_bytes().decode('utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home() / '.config/mouthtype/linux.json')
    runtime_base = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid())))
    state_base = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state'))
    parser.add_argument('--runtime', type=Path, default=runtime_base / 'mouthtype')
    parser.add_argument('--recovery', type=Path, default=state_base / 'mouthtype/recovery')
    parser.add_argument('--imports', type=Path, default=state_base / 'mouthtype/imports')
    commands = parser.add_subparsers(dest='action', required=True)
    doctor = commands.add_parser('doctor', help='Read-only setup checks; no recording or downloads')
    doctor.add_argument('--json', action='store_true', help='Machine-readable setup report')
    commands.add_parser('capabilities', help='Describe this client interface without contacting the service')
    watcher = commands.add_parser('watch', help='Stream text-free state changes as JSON lines')
    watcher.add_argument('--retry', action='store_true', help='Keep reconnecting while the service is absent')
    service = commands.add_parser('serve')
    service.add_argument('--lifetime-seconds', type=float, default=43200)
    for action in ('start', 'stop', 'toggle', 'cancel', 'status', 'shutdown', 'list',
                   'import-status', 'import-cancel', 'import-result', 'import-forget'):
        commands.add_parser(action)
    for action in ('recover', 'transcribe', 'forget'):
        command = commands.add_parser(action)
        command.add_argument('id')
        if action == 'recover':
            command.add_argument('--raw', action='store_true', help='Print original recognition, if saved')
    importer = commands.add_parser('import', help='Transcribe one WAV, AIFF or M4A file through the running service')
    importer.add_argument('path')
    saver = commands.add_parser('import-save', help='Write the latest file transcript as UTF-8 text')
    saver.add_argument('path')
    saver.add_argument('--overwrite', action='store_true', help='Replace an existing text file; never the audio source')
    args = parser.parse_args()
    path = args.runtime / 'session.sock'
    try:
        if args.action == 'capabilities':
            print(json.dumps(CAPABILITIES))
            return 0
        if args.action == 'watch':
            halt = threading.Event()
            for event in (signal.SIGINT, signal.SIGTERM):
                signal.signal(event, lambda *_: halt.set())
            return watch(path, sys.stdout, retry=args.retry, stopped=halt)
        if args.action == 'import-result':
            sys.stdout.write(imports.result_text(args.imports))
            return 0
        if args.action == 'import-save':
            imports.save_text(args.imports, args.path, overwrite=args.overwrite)
            return 0
        if args.action == 'import':
            source = str(Path(args.path).expanduser().resolve())
            print(json.dumps(request(path, 'import', source=source)))
            return 0
        if args.action == 'doctor':
            from doctor import diagnose, render
            report = diagnose(args.config, args.runtime)
            print(json.dumps(report) if args.json else render(report))
            return 0 if report['ready'] else 2
        if args.action == 'list':
            print(json.dumps(recovery_list(args.recovery)))
            return 0
        if args.action == 'recover':
            sys.stdout.write(recovery_result(args.recovery, args.id, raw=args.raw))
            return 0
        if args.action == 'forget':
            take = recovery_path(args.recovery, args.id)
            if path.exists():
                status = request(path, 'status')
                if status.get('recovery') == args.id and status.get('state') != 'idle':
                    raise ValueError('Recovery is in use')
            for name in ('recording.wav', 'transcript.txt', 'raw-recognition.txt'):
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
        dictionary = Path(config['dictionary']).expanduser() if 'dictionary' in config else None
        if dictionary is not None and not dictionary.is_absolute():
            dictionary = args.config.resolve().parent / dictionary
        phrases = Path(config['phrases']).expanduser() if 'phrases' in config else None
        if phrases is not None and not phrases.is_absolute():
            phrases = args.config.resolve().parent / phrases
        args.runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = args.runtime.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Runtime directory must be owned by you with mode 0700')
        engine = SpeechEngine(settings, python=config.get('python', sys.executable),
                              request_seconds=config['request_seconds'])
        cleanup_engine = None
        if config['cleanup'] in ('fast', 'thorough'):
            cleanup_path = Path(config['cleanup_engine']).expanduser()
            if not cleanup_path.is_absolute():
                cleanup_path = args.config.resolve().parent / cleanup_path
            cleanup_settings = json.loads(cleanup_path.read_text())['engines'][config['cleanup']]
            cleanup_engine = CleanupEngine(cleanup_settings)
        session = Session(PipeWireCapture(config.get('capture_target')), engine,
                          HyprlandDelivery(config['delivery']), args.recovery,
                          maximum_seconds=config['maximum_recording_seconds'],
                          feedback=Notifications(config['notifications']), dictionary=dictionary, phrases=phrases,
                          phrase_clipboard=config.get('phrase_clipboard', False), cleanup=config['cleanup'],
                          cleanup_engine=cleanup_engine)
        files = FileTranscription(engine, args.imports, request_seconds=config['request_seconds'])
        if cleanup_engine is not None and cleanup_engine.state == 'idle':
            cleanup_engine.warm()
        session._notify('ready')
        stopped = threading.Event()
        for event in (signal.SIGINT, signal.SIGTERM):
            signal.signal(event, lambda *_: stopped.set())
        try:
            serve(path, session, stopped, lifetime_seconds=args.lifetime_seconds, files=files)
        finally:
            try:
                files.close()
            finally:
                try:
                    session.close()
                finally:
                    if cleanup_engine is not None:
                        cleanup_engine.close()
        return 0
    except FileError as error:
        print(json.dumps({'error': error.code}), file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        # Config paths, model errors and transcripts never go into routine diagnostics.
        print(json.dumps({'error': 'unavailable', 'error_class': type(error).__name__}), file=sys.stderr)
        return 2



class Notifications:
    MESSAGES = {
        'ready': ('Mouthtype is ready', 'Use your configured hold or toggle shortcut.'),
        'recording': ('Mouthtype is recording', 'Release your hold key or press toggle to finish.'),
        'transcribing': ('Mouthtype is transcribing', 'Processing your recording locally.'),
        'saved': ('Mouthtype finished', 'Transcript saved. Check the target before sending.'),
        'delivered': ('Mouthtype finished', 'Sent to the active window. Check the field before sending.'),
        'empty': ('Mouthtype finished', 'No text was returned.'),
        'cancelled': ('Mouthtype cancelled', 'The active take will not be delivered.'),
        'error': ('Mouthtype needs attention', 'Check status and saved recordings.'),
    }

    def __init__(self, enabled=True, *, command=None):
        self.enabled = enabled
        self.command = command or ['notify-send']
        self.status = 'unavailable' if enabled else 'disabled'
        self.identity = None

    def notify(self, state):
        if not self.enabled or state not in self.MESSAGES:
            return False
        title, body = self.MESSAGES[state]
        # Recording cues expire even if a later notification cannot be submitted.
        expiry = 125000 if state in ('recording', 'transcribing') else 5000
        arguments = [*self.command, '--print-id', '--app-name=Mouthtype', '--expire-time=' + str(expiry)]
        if self.identity:
            arguments.append('--replace-id=' + str(self.identity))
        process = None
        try:
            process = subprocess.Popen(arguments + [title, body], stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
            output, _ = process.communicate(timeout=.2)
            if process.returncode != 0:
                raise ValueError('Notification unavailable')
            raw = output.strip()
            if len(raw) <= 10 and raw.isdigit() and 0 < int(raw) <= 4294967295:
                self.identity = int(raw)
            self.status = 'submitted_unknown'
            return True
        except (OSError, ValueError, subprocess.SubprocessError):
            self.status = 'unavailable'
            return False
        finally:
            if process:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=.2)
                except subprocess.TimeoutExpired:
                    pass
                if process.stdout and not process.stdout.closed:
                    process.stdout.close()


if __name__ == '__main__':
    sys.exit(main())
