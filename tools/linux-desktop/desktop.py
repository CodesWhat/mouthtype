"""Mouthtype Linux session service and compositor command client."""

import argparse
from collections import namedtuple
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
from session_client import read_message, request

# Importing these costs tens of milliseconds, and a hotkey or panel client never needs them. They are bound into this
# module on first use (the service, doctor and tests reach them through the constructors below or by attribute).
RUNTIME_NAMES = {
    'Stopped': 'proof', 'VerifiedHashes': 'proof', 'Worker': 'proof', 'verify_artifacts': 'proof',
    'load_spellings': 'spellings', 'load_phrases': 'phrases', 'PhraseContextUnavailable': 'phrases',
    'BasicCleanup': 'cleanup', 'smart': None, 'style_contexts': None, 'tone_stage': None, 'imports': None,
    'FileError': 'imports', 'FileTranscription': 'imports',
}
RUNTIME_MODULES = {'smart': 'smart', 'style_contexts': 'styles', 'tone_stage': 'tone', 'imports': 'imports'}


def load_runtime():
    """Bind the service-side modules into this module's globals. Names already present (a test patch) are kept."""
    import importlib
    scope = globals()
    for name, module in RUNTIME_NAMES.items():
        if name in scope:
            continue
        if module is None:
            scope[name] = importlib.import_module(RUNTIME_MODULES[name])
        else:
            scope[name] = getattr(importlib.import_module(module), name)
    if 'ClipboardTooLarge' not in scope:
        scope['ClipboardTooLarge'] = type('ClipboardTooLarge', (scope['PhraseContextUnavailable'],), {'__module__': __name__})


def __getattr__(name):
    if name in RUNTIME_NAMES or name == 'ClipboardTooLarge':
        load_runtime()
        return globals()[name]
    if name == 'CAPABILITIES':
        return capabilities_report()
    raise AttributeError(f'module {__name__!r} has no attribute {name!r}')
import concealed
from hyprland_ipc import HyprlandIPC, IPCError, IPCTimeout


INTERFACE = 1


def capabilities_report():
    import imports
    return {
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


def hash_cache(*, environ=None):
    """The verified-model-hash cache in the state directory. MOUTHTYPE_VERIFY_FULL=1 forces a full SHA-256 every load."""
    environ = os.environ if environ is None else environ
    base = Path(environ.get('XDG_STATE_HOME') or Path.home() / '.local/state')
    return VerifiedHashes(base / 'mouthtype/verified-models.json',
                          force=environ.get('MOUTHTYPE_VERIFY_FULL', '') not in ('', '0'))


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


# Engine workers run in their own session, so nothing ties them to the service. PR_SET_PDEATHSIG fires when the
# spawning *thread* exits, and the service spawns from short-lived threads, so the worker watches its parent instead.
# Everything in the worker's process group (the speech worker, llama-server) goes down with it.
PARENT_WATCH = '''
import os, runpy, signal, sys, threading, time
parent, script = int(sys.argv[1]), sys.argv[2]
def watch():
    while os.getppid() == parent:
        time.sleep(.5)
    try:
        os.killpg(os.getpgrp(), signal.SIGKILL)
    except OSError:
        os._exit(1)
threading.Thread(target=watch, daemon=True).start()
sys.argv = sys.argv[2:]
sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
runpy.run_path(script, run_name='__main__')
'''


def guarded_command(command):
    """Run `python script args...` so it is killed, with its process group, if this process dies without cleaning up."""
    return [command[0], '-c', PARENT_WATCH, str(os.getpid()), *command[1:]]


class Session:
    HOUSEKEEPING_TAKES = 10
    HOUSEKEEPING_SECONDS = 1800

    def __init__(self, capture, engine, delivery, recovery, *, maximum_seconds=60, clock=None, feedback=None,
                 dictionary=None, phrases=None, phrase_clipboard=False, clipboard=None, cleanup='off',
                 cleanup_engine=None, maximum_takes=200, audio_days=90, audio_megabytes=2048, history_keep=None,
                 styles=None, styles_path=None, engine_loader=None, slash_commands=True):
        load_runtime()
        self.capture, self.engine, self.delivery = capture, engine, delivery
        self.maximum_takes, self.audio_days, self.audio_megabytes = maximum_takes, audio_days, audio_megabytes
        self.history_keep = history_keep
        self.cleanup_engine = cleanup_engine
        # One resident model per level a take can run at: the global level's, plus any a Style context overrides to.
        self.cleanup_engines = {cleanup: cleanup_engine} if cleanup_engine is not None and cleanup in ('fast', 'thorough') else {}
        self.engine_loader = engine_loader
        self.styles, self.styles_path, self.styles_stamp = self._usable_styles(styles), styles_path, None
        self._rejected_stamp = None
        self._refresh_styles()
        self.cleanup_outcome, self.cleanup_ms = None, None
        self.feedback = feedback
        self.dictionary = dictionary
        self.phrases = phrases
        self.cleanup = cleanup
        self.slash_commands = slash_commands
        self.phrase_clipboard = phrase_clipboard
        self.clipboard = clipboard or read_phrase_clipboard
        self.recovery = Path(recovery)
        self.recovery.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.recovery.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Recovery directory must be private and owned by you')
        self.maximum_seconds, self.clock = maximum_seconds, clock or time.monotonic
        self.lock = threading.RLock()
        self.take_times = {}
        self.pruned = threading.Event()
        self.takes_since_retire = self.HOUSEKEEPING_TAKES
        self.retired_at = time.monotonic()
        self.state, self.error, self.outcome = 'idle', None, 'not_attempted'
        self.thread = None
        self.cancelled = threading.Event()
        self.take = None
        self.discard_on_cancel = False
        self.closed = False
        # True while a delivery runs outside the lock; close() waits longer for it than for inference.
        self.delivering = False
        try:
            import inspect
            parameters = inspect.signature(delivery.submit).parameters
            self._cancellable_delivery = 'cancelled' in parameters
            self._verifiable_delivery = 'verified' in parameters
        except (TypeError, ValueError):
            self._cancellable_delivery = self._verifiable_delivery = False

    @staticmethod
    def _usable_styles(value):
        """The validated styles block, or None when it is absent or all defaults (nothing then changes)."""
        if value is None:
            return None
        block = style_contexts.validate(value)
        return block if style_contexts.to_config(block) is not None else None

    def _refresh_styles(self):
        """Pick up `style-*` edits made while the service runs. Reads the file only when its mtime or size changed,
        and keeps the styles already loaded when the file can't be read or no longer validates."""
        if self.styles_path is None:
            return
        try:
            info = os.stat(self.styles_path)
            stamp = (info.st_mtime_ns, info.st_size)
            if stamp == self.styles_stamp:
                return
            block = self._usable_styles(style_contexts.read_block(self.styles_path))
        except OSError:
            return
        except Exception as error:
            # Any malformed edit keeps the styles already loaded. Say so once per file state, not on every take.
            if stamp != self._rejected_stamp:
                self._rejected_stamp = stamp
                print(json.dumps({'error': 'styles_invalid', 'error_class': type(error).__name__}), file=sys.stderr)
            return
        self.styles, self.styles_stamp = block, stamp

    def _style_window(self):
        """The take-start window for style resolution only, whatever the delivery mode. Other when unknown."""
        lookup = getattr(self.delivery, 'window_class', None)
        try:
            window_class = lookup() if lookup is not None else None
        except Exception:
            return None
        return {'class': window_class} if isinstance(window_class, str) and window_class else None

    def _plan(self, target):
        """What one take runs: the model level, its engine and the tone to re-apply after the model.

        Without a styles block this is the global level and no tone, exactly as before styles existed."""
        plan = {'level': self.cleanup, 'tone': None, 'engine': self.cleanup_engine}
        if self.styles is None:
            return plan
        resolved = style_contexts.resolve(self.styles, target.get('class') if isinstance(target, dict) else None)
        wanted = resolved['cleanup'] or self.cleanup
        if wanted in ('fast', 'thorough') and wanted not in self.cleanup_engines and self.engine_loader is not None:
            try:
                engine = self.engine_loader(wanted)
            except (OSError, ValueError, KeyError, TypeError):
                engine = None
            if engine is not None:
                self.cleanup_engines[wanted] = engine
                if engine.state == 'idle':
                    engine.warm()
        level = style_contexts.effective_cleanup(resolved, self.cleanup, tuple(self.cleanup_engines))
        return {'level': level, 'tone': resolved['tone'], 'engine': self.cleanup_engines.get(level)}

    def take_count(self):
        with os.scandir(self.recovery) as entries:
            return sum(1 for entry in entries if entry.is_dir(follow_symlinks=False))

    @staticmethod
    def take_time(path):
        """When the take was made. Never the directory mtime, which moves whenever a file inside is removed."""
        try:
            created = json.loads((path / 'take.json').read_text())['created']
            if type(created) in (int, float) and math.isfinite(created):
                return created
        except (OSError, ValueError, KeyError, TypeError):
            pass
        # Takes from before take.json: the earliest surviving file, which expiring the WAV cannot move.
        stamps = []
        for child in path.iterdir():
            try:
                if child.is_file():
                    stamps.append(child.stat().st_mtime)
            except OSError:
                pass
        return min(stamps) if stamps else path.stat().st_mtime

    def known_take_time(self, path):
        """take_time, remembered by take name: a take's creation time never moves, so repeat scans skip the reads."""
        known = self.take_times.get(path.name)
        if known is None:
            known = self.take_times[path.name] = self.take_time(path)
        return known

    def prune_history(self):
        """Keep only the newest `history_keep` takes, forgetting the rest entirely. The active take is never touched."""
        if not self.history_keep:
            return 0
        removed = 0
        # The walk runs without the session lock, so a hotkey is never queued behind a large history. Only the delete
        # step holds it, and it re-checks the active take: recover_audio may have picked a listed take meanwhile.
        takes = []
        with os.scandir(self.recovery) as entries:
            for entry in entries:
                if not entry.is_dir(follow_symlinks=False) or not re.fullmatch('[0-9a-f]{32}', entry.name):
                    continue
                path = Path(entry.path)
                try:
                    takes.append((self.known_take_time(path), path.name, path))
                except OSError:
                    continue
        self.take_times = {name: self.take_times[name] for _, name, _ in takes if name in self.take_times}
        if len(takes) <= self.history_keep:
            return 0
        takes.sort(reverse=True)
        doomed = [path for _, _, path in takes[self.history_keep:]]
        with self.lock:
            for path in doomed:
                if path == self.take:
                    continue
                for name in ('recording.wav', 'transcript.txt', 'raw-recognition.txt', 'cleanup.json', 'take.json'):
                    (path / name).unlink(missing_ok=True)
                try:
                    path.rmdir()
                    removed += 1
                except OSError:
                    pass
        return removed

    def retire_completed_audio(self, now=None):
        """Mirror the Mac saved-audio policy: drop completed takes' WAVs past the age or size limit, keep their text."""
        now = time.time() if now is None else now
        completed = []
        with self.lock:
            active = self.take
        with os.scandir(self.recovery) as entries:
            for entry in entries:
                if not entry.is_dir(follow_symlinks=False):
                    continue
                path = Path(entry.path)
                if path == active:
                    continue
                audio, transcript = path / 'recording.wav', path / 'transcript.txt'
                if audio.is_file() and transcript.is_file():
                    try:
                        info = audio.stat()
                    except OSError:
                        continue
                    completed.append((info.st_mtime, info.st_size, audio))
        completed.sort()
        kept_bytes = sum(size for _, size, _ in completed)
        limit = self.audio_megabytes * 1024 * 1024 if self.audio_megabytes else None
        doomed = []
        for mtime, size, audio in completed:
            expired = self.audio_days is not None and now - mtime > self.audio_days * 86400
            oversize = limit is not None and kept_bytes > limit
            if not expired and not oversize:
                continue
            doomed.append((size, audio))
            kept_bytes -= size
        removed = 0
        with self.lock:
            for size, audio in doomed:
                if audio.parent == self.take:
                    continue
                try:
                    audio.unlink()
                    removed += 1
                except OSError:
                    pass
        return removed

    def housekeep(self, *, force=False):
        """Retention after a take. The audio walk is throttled to every HOUSEKEEPING_TAKES takes or
        HOUSEKEEPING_SECONDS; the first take after startup always runs it. History pruning is cheap and exact, so it
        runs every time."""
        with self.lock:
            self.takes_since_retire += 1
            due = force or self.takes_since_retire >= self.HOUSEKEEPING_TAKES or \
                time.monotonic() - self.retired_at >= self.HOUSEKEEPING_SECONDS
            if due:
                self.takes_since_retire, self.retired_at = 0, time.monotonic()
        # Pruning frees recovery slots, so it goes first and signals; the slow audio walk follows.
        try:
            self.prune_history()
        finally:
            self.pruned.set()
        if due:
            self.retire_completed_audio()

    def status(self):
        return {'state': self.state, 'error': self.error, 'delivery': self.outcome,
                'takes': self.take_count(), 'maximum_takes': self.maximum_takes, 'history_keep': self.history_keep,
                'recovery': self.take.name if self.take else None,
                'context': 'unsupported', 'secure_field_detection': 'unsupported',
                'delivery_verified': False,
                'cleanup': {'level': self.cleanup, 'last_outcome': self.cleanup_outcome, 'last_ms': self.cleanup_ms,
                            'model': self.cleanup_engine.status() if self.cleanup_engine is not None else None},
                'feedback': getattr(self.feedback, 'status', 'unavailable') if self.feedback else 'disabled'}

    def live_status(self):
        """The fields a watcher snapshot needs, without the take-directory walk that status() does."""
        return {'state': self.state, 'error': self.error, 'delivery': self.outcome,
                'recovery': self.take.name if self.take else None}

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
                self._refresh_styles()
                try:
                    cleanup = BasicCleanup('basic' if self.cleanup in ('fast', 'thorough') else self.cleanup, self.styles,
                                            self.slash_commands)
                except ValueError:
                    self.error = 'cleanup_unavailable'
                    self._notify('error')
                    return self.status()
                target = self.delivery.snapshot()
                style_target = target if target is not None else self._style_window()
                plan = self._plan(style_target)
                if admit_before is not None and time.monotonic() >= admit_before:
                    self.error = 'command_expired'
                    return self.status()
                if self.take_count() >= self.maximum_takes:
                    self.error = 'recovery_full'
                    return self.status()
                self.take = self.recovery / uuid.uuid4().hex
                try:
                    self.take.mkdir(mode=0o700)
                    private_write(self.take / 'take.json', json.dumps({'created': time.time()}))
                except (OSError, ValueError):
                    # A take that can't record its own metadata must not hold a recovery slot.
                    (self.take / 'take.json').unlink(missing_ok=True)
                    try:
                        self.take.rmdir()
                    except OSError:
                        pass
                    self.take = None
                    self.error = 'capture_unavailable'
                    self._notify('error')
                    return self.status()
                self.discard_on_cancel = True
                self.target, self.style_target = target, style_target
                self.spellings = spellings
                self.phrase_rules = phrases
                self.cleanup_rules = cleanup
                self.cleanup_plan = plan
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
                        (self.take / 'take.json').unlink(missing_ok=True)
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
                                               args=(self.take, self.cancelled, self.target, self.spellings, self.phrase_rules, self.cleanup_rules),
                                               kwargs={'plan': self.cleanup_plan, 'style_target': self.style_target})
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
                (self.take / 'take.json').unlink(missing_ok=True)
            try:
                self.take.rmdir()
            except OSError:
                pass

    def _finish(self, take, cancelled, target, spellings, phrases, cleanup, allow_delivery=True, plan=None, style_target=None):
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
            if plan is None:
                plan = {'level': self.cleanup, 'tone': None, 'engine': self.cleanup_engine}
            basic = cleanup.apply(raw, target if target is not None else style_target)
            outcome, milliseconds = self._model_cleanup(basic, cancelled, plan['level'], plan['engine'])
            text = basic if outcome is None or not isinstance(outcome[1], str) else outcome[1]
            if outcome is not None and isinstance(outcome[1], str) and plan['tone']:
                # Match Core: a model can't undo the tone, and Formal still softens any swearing it put back.
                text = tone_stage.apply(text, plan['tone'])
            text = phrases.apply(spellings.apply(text))
            with self.lock:
                if cancelled.is_set() or self.closed:
                    return
                private_write(take / 'transcript.txt', text)
                if outcome is not None:
                    self.cleanup_outcome, self.cleanup_ms = outcome[0], milliseconds
                    private_write(take / 'cleanup.json', json.dumps({'level': plan['level'], 'outcome': outcome[0],
                                                                      'milliseconds': milliseconds, 'reason': outcome[2]}))
                self.outcome = 'empty' if not text else 'recover_only' if not allow_delivery else 'target_changed'
                deliver = bool(allow_delivery and text and target == self.delivery.snapshot())
                self.delivering = deliver
                if not deliver:
                    self.state = 'idle'
                    self._notify('saved' if text else 'empty')
            if deliver:
                # Delivery shells out and can take seconds, so status, tick and level must not wait on it. The state
                # stays 'transcribing', which keeps a new take from starting underneath the paste.
                try:
                    # A cancel that lands before the clipboard or keys are touched stops the delivery.
                    # The snapshot above just confirmed the target, so paste skips its own duplicate of that check.
                    options = {'cancelled': cancelled} if self._cancellable_delivery else {}
                    if self._verifiable_delivery:
                        options['verified'] = True
                    outcome = self.delivery.submit(text, target, **options)
                finally:
                    with self.lock:
                        self.delivering = False
                with self.lock:
                    if self.cancelled is cancelled:
                        # The text was sent whatever happened meanwhile, so the outcome is recorded either way.
                        self.outcome = outcome
                        if not cancelled.is_set() and not self.closed:
                            # Audio remains available after delivery uncertainty; success is never inferred.
                            self.state = 'idle'
                            self._notify('delivered' if outcome == 'unknown' else 'saved')
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            with self.lock:
                if not cancelled.is_set() and not self.closed:
                    self.error, self.state = 'transcription_failed', 'idle'
                    self._notify('error')
        finally:
            with self.lock:
                if cancelled.is_set() and self.cancelled is cancelled and self.state == 'cancelling':
                    self.state = 'idle'
            try:
                self.housekeep()
            except OSError:
                pass

    def _model_cleanup(self, basic, cancelled, level=None, engine=None):
        """Run the resident model on the deterministic text within its budget. Any trouble keeps the basic text."""
        if level is None:
            level, engine = self.cleanup, self.cleanup_engine
        if level not in ('fast', 'thorough') or engine is None:
            return None, None
        if not smart.eligible(basic):
            return ('skipped', None, None), 0
        started = time.monotonic()
        seconds = smart.budget_seconds(level, smart.word_count(basic))
        try:
            model = engine.clean(basic, cancelled, seconds=seconds)
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
            self._refresh_styles()
            try:
                cleanup = BasicCleanup('basic' if self.cleanup in ('fast', 'thorough') else self.cleanup, self.styles,
                                            self.slash_commands)
            except ValueError:
                self.error = 'cleanup_unavailable'
                self._notify('error')
                return self.status()
            plan = self._plan(None)
            self.take = take
            self.discard_on_cancel = False
            self.cancelled = threading.Event()
            self.error, self.outcome, self.state = None, 'not_attempted', 'transcribing'
            self._notify('transcribing')
            self.thread = threading.Thread(target=self._finish, args=(take, self.cancelled, None, spellings, phrases, cleanup, False),
                                           kwargs={'plan': plan})
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
        try:
            # A paste already past its last cancel check can take its helpers' full timeouts to finish.
            self.wait(30 if self.delivering else 3)
        finally:
            self.engine.close()

class HyprlandDelivery:
    IPC_TIMEOUT = .5

    def __init__(self, config, run=None, ipc=None):
        load_runtime()
        self.config, self.run = config, run or subprocess.run
        # Only the real subprocess path talks to the socket; an injected runner stands in for hyprctl itself.
        self.ipc = ipc if ipc is not None else HyprlandIPC() if run is None else None

    def _query(self, name, limit=IPC_TIMEOUT):
        """Hyprland's JSON reply for one query. The socket answers when it can; any other failure goes to hyprctl."""
        started = time.monotonic()
        if self.ipc is not None:
            try:
                return self.ipc.request('j/' + name, limit)
            except IPCTimeout:
                raise subprocess.TimeoutExpired('hyprctl', limit) from None
            except IPCError:
                limit = max(limit - (time.monotonic() - started), .05)
        return self.run(['hyprctl', '-j', name], capture_output=True, text=True, check=True, timeout=limit).stdout

    def _dispatch(self, argv, limit):
        """Run a hyprctl dispatch argv through the socket, or through hyprctl when the socket can't take it."""
        if self.ipc is not None:
            try:
                reply = self.ipc.request('/' + ' '.join(argv[1:]), limit)
                if reply.strip() != 'ok' and 'ok'.startswith(reply.strip()):
                    # Sent, but the answer is empty or cut short: the chord may have run, so no other form may follow.
                    raise subprocess.TimeoutExpired('hyprctl', limit)
                return type('Result', (), {'returncode': 0, 'stdout': reply, 'stderr': ''})()
            except IPCError as error:
                if error.sent:
                    # The dispatcher may have run it; a retry could paste twice.
                    raise subprocess.TimeoutExpired('hyprctl', limit) from None
        result = self.run(argv, capture_output=True, text=True, check=False, timeout=limit)
        output = ((getattr(result, 'stdout', '') or '') + (getattr(result, 'stderr', '') or '')).strip()
        if output != 'ok' and 'ok'.startswith(output):
            # The dispatch was issued but nothing, or half an answer, came back: it may have run.
            raise subprocess.TimeoutExpired('hyprctl', limit)
        return result

    def snapshot(self):
        if self.config.get('mode') not in ('type', 'paste'):
            return None
        try:
            lock_state = json.loads(self._query('locked'))
            if not isinstance(lock_state, dict) or lock_state.get('locked') is not False:
                return None
            active = json.loads(self._query('activewindow'))
            if (not isinstance(active.get('address'), str) or not active['address'] or
                    not isinstance(active.get('class'), str) or not active['class'] or
                    type(active.get('pid')) is not int or active['pid'] <= 0):
                return None
            return {key: active[key] for key in ('address', 'class', 'pid')}
        except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
            return None

    def window_class(self):
        """The active window's class for style resolution. Unlike snapshot() it also answers in recover mode, and
        it never authorises delivery. None when the query fails or times out."""
        if self.config.get('mode') in ('type', 'paste'):
            return None
        try:
            window_class = json.loads(self._query('activewindow')).get('class')
        except (OSError, ValueError, TypeError, AttributeError, subprocess.SubprocessError):
            return None
        return window_class if isinstance(window_class, str) and window_class else None

    # Terminals paste with Ctrl+Shift+V, and a pasted line break runs a command there.
    TERMINAL_CLASSES = ('Alacritty', 'kitty', 'foot', 'footclient', 'com.mitchellh.ghostty', 'org.wezfurlong.wezterm',
                        'konsole', 'org.kde.konsole', 'org.gnome.Terminal', 'gnome-terminal-server', 'xterm', 'st',
                        'com.github.contour-terminal.contour', 'Terminal', 'tilix', 'com.gexperts.Tilix',
                        'org.omarchy.agent')
    # A terminal launched with a custom window class is still a terminal; its process name says so.
    TERMINAL_EXECUTABLES = ('ghostty', 'alacritty', 'kitty', 'foot', 'footclient', 'wezterm-gui', 'wezterm', 'konsole',
                            'gnome-terminal-server', 'gnome-terminal', 'xterm', 'st', 'tilix', 'contour', 'rio',
                            'xfce4-terminal', 'urxvt', 'terminator', 'ptyxis', 'wayst', 'blackbox', 'tabby')

    COMM_LENGTH = 15

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
        name = self.process_name(target.get('pid'))
        # The kernel truncates comm to 15 characters, so 'gnome-terminal-server' reads back as 'gnome-terminal-'.
        return name is not None and name[:self.COMM_LENGTH] in {item[:self.COMM_LENGTH] for item in executables}

    def submit(self, text, target, cancelled=None, verified=False):
        if not self.allowed(target):
            return 'recover_only'
        if cancelled is not None and cancelled.is_set():
            return 'not_attempted'
        if self.config.get('mode') == 'type':
            # wtype maps these to physical actions (Return, Tab, Escape), not literal text.
            if any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in text):
                return 'unsupported_text'
            if self.snapshot() != target:
                return 'target_changed'
            if cancelled is not None and cancelled.is_set():
                return 'not_attempted'
            try:
                self.run(['wtype', '-'], input=text.encode('utf-8'), stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, check=True, timeout=15,
                         env={**os.environ, 'LC_ALL': 'C.UTF-8'})
            except (OSError, subprocess.SubprocessError):
                # The helper could have sent a prefix. Never replay automatically.
                return 'unknown'
            return 'unknown'
        return self.paste(text, target, cancelled, verified)

    def paste(self, text, target, cancelled=None, verified=False):
        """Clipboard plus a paste chord. Line breaks and tabs travel as text; other controls are refused."""
        terminal = self.is_terminal(target)
        if terminal:
            # A trailing line break would run the command, so it never travels; the check below sees the exact payload.
            text = text.rstrip('\r\n')
        if any((ord(char) < 32 and char not in '\n\t') or 127 <= ord(char) <= 159 for char in text):
            return 'unsupported_text'
        if terminal and ('\n' in text or '\r' in text) and self.config.get('allow_terminal_multiline') is not True:
            return 'unsupported_text'
        # verified: the caller snapshotted this target an instant ago. The check after wl-copy still guards the chord.
        if not verified and self.snapshot() != target:
            return 'target_changed'
        previous = None
        if self.config.get('restore_clipboard', True):
            types = self.clipboard_types()
            if types and any(item in self.SENSITIVE_TYPES for item in types):
                # A password manager marked it. Overwriting is fine; putting it back would republish the secret.
                types = None
            elif types and not self.restorable(types):
                # An image or file list can't be put back as text, so overwriting it would destroy it.
                return 'recover_only'
            if types is not None:
                try:
                    previous = self.clipboard()
                except ClipboardTooLarge:
                    return 'recover_only'
                except (OSError, ValueError, PhraseContextUnavailable, subprocess.SubprocessError):
                    previous = None
        if cancelled is not None and cancelled.is_set():
            return 'not_attempted'
        try:
            self.run(concealed.copy_command(), input=text.encode('utf-8'),
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=5)
            # The clipboard owner forks; the target only sees the new offer once it is live.
            if not self.wait_for_clipboard(text):
                return 'unknown'
            if self.snapshot() != target:
                return 'target_changed'
            if cancelled is not None and cancelled.is_set():
                # Our text is already on the clipboard; the finally block puts the earlier one back.
                return 'not_attempted'
            outcome = self.send_paste_chord(target, terminal, cancelled)
            if outcome:
                return outcome
        except (OSError, subprocess.SubprocessError):
            return 'unknown'
        finally:
            if previous is not None:
                self.schedule_restore(previous, text)
        return 'unknown'

    settle_seconds = 1.5
    restore_delay_seconds = 1.5
    restore_thread = None
    SENSITIVE_TYPES = ('x-kde-passwordManagerHint',)
    TEXT_TYPES = ('UTF8_STRING', 'STRING', 'TEXT', 'COMPOUND_TEXT')
    # Offers that mean the content is more than text, even when a plain-text flavour rides along.
    BINARY_PREFIXES = ('image/', 'audio/', 'video/', 'x-special/')

    @classmethod
    def restorable(cls, types):
        """True when putting back the plain-text flavour reproduces what the clipboard held."""
        if not any(item.startswith('text/plain') or item in cls.TEXT_TYPES for item in types):
            return False
        return not any(item.startswith(cls.BINARY_PREFIXES) or item == 'text/uri-list' for item in types)

    def clipboard_types(self):
        """MIME types the clipboard offers: [] when it is empty, None when that can't be learned."""
        try:
            result = self.run(['wl-paste', '--list-types'], capture_output=True, text=True, check=False, timeout=1)
        except (OSError, subprocess.SubprocessError):
            return None
        if getattr(result, 'returncode', 1) != 0:
            return []
        output = getattr(result, 'stdout', '')
        return [line.strip() for line in output.splitlines() if line.strip()] if isinstance(output, str) else None

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

    def send_paste_chord(self, target, terminal, cancelled=None):
        """Hyprland delivers the chord to the captured window itself; wtype is the fallback for other compositors.

        Returns None once sent, or an outcome string when the chord must not be sent blindly."""
        mods = 'CTRL SHIFT' if terminal else 'CTRL'
        window = 'address:' + str(target.get('address', ''))
        attempts = (
            ['hyprctl', 'dispatch', 'hl.dsp.send_shortcut({mods=%s, key="v", window=%s})' % (json.dumps(mods), json.dumps(window))],
            ['hyprctl', 'dispatch', 'sendshortcut', mods.replace(' ', '+') + ',v,' + window],
        )
        for argv in attempts:
            if cancelled is not None and cancelled.is_set():
                return 'not_attempted'
            try:
                result = self._dispatch(argv, 5)
            except subprocess.TimeoutExpired:
                # The dispatcher may still have delivered the chord; a second one could paste twice.
                return 'unknown'
            except (OSError, subprocess.SubprocessError):
                continue
            output = (getattr(result, 'stdout', '') or '') + (getattr(result, 'stderr', '') or '')
            if getattr(result, 'returncode', 1) == 0 and 'ok' in output and 'error' not in output.lower():
                return None
        # wtype is untargeted, so only use it while the captured window is still the active one.
        if self.snapshot() != target:
            return 'target_changed'
        if cancelled is not None and cancelled.is_set():
            return 'not_attempted'
        chord = (['wtype', '-M', 'ctrl', '-M', 'shift', '-k', 'v', '-m', 'shift', '-m', 'ctrl'] if terminal
                 else ['wtype', '-M', 'ctrl', '-k', 'v', '-m', 'ctrl'])
        self.run(chord, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=15)

    def clipboard(self):
        return read_phrase_clipboard()

    def schedule_restore(self, previous, ours, *, delay=None):
        """Put the earlier text clipboard back once the target has had time to read ours, unless something newer owns it."""
        if delay is None:
            delay = self.config.get('restore_delay_seconds', self.restore_delay_seconds)

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
    load_runtime()
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
                    raise ClipboardTooLarge('Clipboard phrase context exceeds its limit')
        if process.wait(timeout=max(0, end - time.monotonic())) != 0:
            raise PhraseContextUnavailable('Clipboard phrase context is unavailable')
        return output.decode('utf-8')
    finally:
        process.stdout.close()
        stop_process(process)


class PipeWireCapture:
    def __init__(self, target=None, *, errors=subprocess.DEVNULL, present=None):
        self.target, self.process, self.path = target, None, None
        self.errors = errors
        self.present = present

    def argv(self, path):
        result = ['pw-record', '--rate=16000', '--channels=1', '--format=s16']
        # A configured microphone that has been unplugged falls back to the default source instead of failing every take.
        # When PipeWire can't be asked, the target is kept as configured.
        if self.target:
            from microphones import target_present
            if (self.present or target_present)(self.target) is not False:
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
    def __init__(self, settings, *, python=sys.executable, worker=None, request_seconds=30, startup_seconds=120,
                 hash_cache=None):
        load_runtime()
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
        self.hash_cache = hash_cache
        self.lock = threading.Lock()
        self.shutdown = threading.Event()
        self.warming = None
        self.warm_guard = threading.Lock()

    def _ensure_loaded(self, cancelled):
        if self.worker is None:
            verify_artifacts(self.settings, self.hash_cache)
            self.worker = Worker(guarded_command([self.python, str(self.script), 'speech']))
            remaining = self.worker.send({'configuration': self.settings}, self.startup_seconds, cancelled)
            ready = self.worker.receive(remaining, cancelled)
            if ready.get('event') != 'ready':
                raise ValueError('Speech engine is unavailable')

    def warm(self):
        """Load in the background so the first take does not pay the hash and model load. A failure just leaves the
        engine cold; the first take retries and reports its own error."""
        def run():
            with self.lock:
                if self.shutdown.is_set():
                    return
                try:
                    self._ensure_loaded(self.shutdown)
                except (OSError, ValueError, KeyError, TypeError, Stopped):
                    self.close()
        with self.warm_guard:
            if self.warming is not None and self.warming.is_alive():
                return self.warming
            self.warming = threading.Thread(target=run, daemon=True)
            self.warming.start()
            return self.warming

    def stop(self):
        self.shutdown.set()
        with self.lock:
            self.close()

    def transcribe(self, path, cancelled, *, seconds=None):
        seconds = self.request_seconds if seconds is None else seconds
        with self.lock:
            try:
                self._ensure_loaded(cancelled)
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

    RETRY_SECONDS = (30, 120, 480, 1800)
    ABSENT_RECHECK_SECONDS = 30

    def __init__(self, settings, *, python=sys.executable, worker=None, startup_seconds=300, clock=time.monotonic,
                 hash_cache=None):
        load_runtime()
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
        self.hash_cache = hash_cache
        self.worker = None
        self.lock = threading.Lock()
        # close() sets this so a load in progress stops promptly instead of holding the lock for minutes.
        self.shutdown = threading.Event()
        self.warming = None
        self.warm_guard = threading.Lock()
        self.clock = clock
        # A failed load retries from clean() on a growing delay; a reload of the config builds a fresh engine.
        self.failures, self.retry_at = 0, 0.0
        self.artifacts_checked = clock()
        self.endpoint = None
        self.state = 'idle' if self._artifacts_present() else 'absent'
        self.error = None
        self.load_ms = None

    def _artifacts_present(self):
        return all(Path(item['path']).is_file() for item in self.settings['artifacts'].values())

    def _recover(self):
        """Called from clean() while not ready. Starts a background load when one is due; never waits."""
        if self.shutdown.is_set():
            return
        if self.state == 'idle':
            self.warm()
        elif self.state == 'failed' and self.clock() >= self.retry_at:
            self.warm()
        elif self.state == 'absent' and self.clock() - self.artifacts_checked >= self.ABSENT_RECHECK_SECONDS:
            self.artifacts_checked = self.clock()
            if self._artifacts_present():
                self.state = 'idle'
                self.warm()

    def status(self):
        return {'state': self.state, 'error': self.error, 'load_ms': self.load_ms,
                'prompt': self.settings.get('prompt', 's1')}

    def _ensure_loaded(self, cancelled):
        if self.worker is not None:
            return
        self.state = 'loading'
        started = time.monotonic()
        verify_artifacts(self.settings, self.hash_cache)
        configuration = {**self.settings, 'startup_seconds': self.startup_seconds}
        if self.hash_cache is not None and not self.hash_cache.force:
            configuration['version_cache'] = str(self.hash_cache.path.with_name('llama-version.json'))
        self.worker = Worker(guarded_command([self.python, str(self.script), 'cleanup']))
        remaining = self.worker.send({'configuration': configuration}, self.startup_seconds, cancelled)
        ready = self.worker.receive(remaining, cancelled)
        if ready.get('event') != 'ready':
            raise ValueError('Cleanup engine is unavailable')
        self.load_ms = int((time.monotonic() - started) * 1000)
        port, alias = ready.get('port'), ready.get('alias')
        self.endpoint = {'port': port, 'alias': alias} if type(port) is int and isinstance(alias, str) else None
        self.state = 'ready'
        self.error = None
        self.failures, self.retry_at = 0, 0.0

    def warm(self):
        """Load in the background so the first take does not pay the cold start."""
        def run():
            with self.lock:
                try:
                    self._ensure_loaded(self.shutdown)
                    self._prime()
                except (OSError, ValueError, KeyError, TypeError, Stopped) as error:
                    self._fail(error)
        with self.warm_guard:
            if self.warming is not None and self.warming.is_alive():
                return self.warming
            self.warming = threading.Thread(target=run, daemon=True)
            self.warming.start()
            return self.warming

    def _prime(self):
        """One short request so the server caches the system prompt; the first real take then pays only for its words."""
        try:
            identity = uuid.uuid4().hex
            remaining = self.worker.send({'id': identity, 'input': 'Warm up, please.', 'deadline_seconds': 60},
                                         60, self.shutdown)
            self.worker.receive(remaining, self.shutdown)
        except (OSError, ValueError, KeyError, TypeError, Stopped):
            pass

    def _fail(self, error):
        self.state, self.error = 'failed', type(error).__name__
        self.retry_at = self.clock() + self.RETRY_SECONDS[min(self.failures, len(self.RETRY_SECONDS) - 1)]
        self.failures += 1
        self.endpoint = None
        worker, self.worker = self.worker, None
        if worker:
            worker.close()

    def clean(self, text, cancelled, *, seconds, controls=None):
        """The model's text, or None when the request timed out or the server is not warm yet.

        A cold server never blocks a take: it loads in the background and this take keeps its basic text."""
        if self.worker is None or self.state != 'ready':
            self._recover()
            return None
        end = time.monotonic() + seconds
        while not self.lock.acquire(timeout=.05):
            if cancelled.is_set() or time.monotonic() >= end:
                return None
        try:
            if self.worker is None or self.state != 'ready':
                return None
            try:
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
                if isinstance(error, Stopped) and str(error) == 'cancelled':
                    # A cancelled request isn't an engine fault: reload on the next take, with no backoff owed.
                    self.failures, self.retry_at = max(0, self.failures - 1), 0.0
                    if Path(self.settings['artifacts']['model']['path']).is_file():
                        self.state = 'idle'
                raise RuntimeError('Cleanup engine unavailable') from None
        finally:
            self.lock.release()

    def info(self):
        """What another local process needs to share this engine's running server instead of loading the model again."""
        model = self.settings['artifacts']['model']
        return {'state': self.state, 'sha256': model['sha256'], 'server': os.path.realpath(self.settings['server']),
                'port': self.endpoint['port'] if self.endpoint and self.state == 'ready' else None,
                'alias': self.endpoint['alias'] if self.endpoint and self.state == 'ready' else None}

    def close(self):
        self.shutdown.set()
        with self.lock:
            self.endpoint = None
            worker, self.worker = self.worker, None
            if worker:
                worker.close()
            if self.state in ('ready', 'loading'):
                self.state = 'idle'


def validate_config(value):
    load_runtime()
    if not isinstance(value, dict) or not isinstance(value.get('engine_config'), str):
        raise ValueError('engine_config is required')
    result = {'maximum_recording_seconds': 60, 'request_seconds': 30, 'maximum_recovery_takes': 200,
              'audio_retention_days': 90, 'audio_retention_megabytes': 2048, 'history_keep': None,
              'delivery': {'mode': 'recover'}, 'notifications': True, 'cleanup': 'off', **value}
    if type(result['notifications']) is not bool:
        raise ValueError('notifications must be true or false')
    for field, minimum, maximum in (('maximum_recording_seconds', 1, 120), ('request_seconds', 1, 120),
                                    ('maximum_recovery_takes', 1, 5000)):
        number = result[field]
        if type(number) not in (int, float) or not math.isfinite(number) or not minimum <= number <= maximum:
            raise ValueError('Invalid finite ' + field)
    for field, minimum, maximum in (('audio_retention_days', 1, 3650), ('audio_retention_megabytes', 1, 1024 * 1024),
                                    ('history_keep', 1, 5000)):
        number = result[field]
        if number is not None and (type(number) not in (int, float) or not math.isfinite(number) or not minimum <= number <= maximum):
            raise ValueError(field + ' must be null or a finite number in range')
    keep = result['history_keep']
    if keep is not None:
        if keep != int(keep):
            raise ValueError('history_keep must be a whole number')
        result['history_keep'] = int(keep)
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
    if 'restore_delay_seconds' in delivery:
        delay = delivery['restore_delay_seconds']
        if type(delay) not in (int, float) or not math.isfinite(delay) or not .1 <= delay <= 30:
            raise ValueError('delivery.restore_delay_seconds must be between 0.1 and 30')
    if 'styles' in result:
        style_contexts.validate(result['styles'])
    if type(result.get('phrase_clipboard', False)) is not bool:
        raise ValueError('phrase_clipboard must be true or false')
    if type(result.get('slash_commands', True)) is not bool:
        raise ValueError('slash_commands must be true or false')
    return result


def serve(path, session, stopped, *, lifetime_seconds=43200, files=None, startup=None, bound=None):
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
            if bound is not None:
                bound()
            maintenance = None
            if startup is not None:
                # Maintenance prunes takes, so only the daemon that owns the runtime lock may run it. It runs after the
                # bind so a large history never delays the first hotkey, and the lock-holding steps it takes are short.
                def run_maintenance():
                    try:
                        startup()
                    except OSError:
                        pass
                maintenance = threading.Thread(target=run_maintenance, daemon=True)
                maintenance.start()
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
                            elif action == 'engine':
                                result = engine_info(session)
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
                                starting = action == 'start' or (action == 'toggle' and session.state == 'idle')
                                if (starting and maintenance is not None and maintenance.is_alive()
                                        and session.take_count() >= session.maximum_takes):
                                    # Startup pruning may be about to free a slot; wait for it, within the deadline,
                                    # rather than answer recovery_full to the first key press. Stop, cancel and a toggle that
                                    # ends a recording never wait.
                                    until = min(time.monotonic() + 1.0, admission - .25)
                                    while maintenance.is_alive() and not session.pruned.is_set() and time.monotonic() < until:
                                        time.sleep(.01)
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
                            # Existing watchers keep comparing against what they were last sent. Adopting this
                            # snapshot would hide an idle transition that landed after it was taken.
                            if not watchers:
                                last_snapshot = result
                            watchers.append(connection)
                    finally:
                        if not keep:
                            connection.close()
            finally:
                if maintenance is not None:
                    maintenance.join(2)
                for watcher in watchers:
                    try:
                        watcher.sendall(json.dumps({'event': 'stopping'}).encode() + b'\n')
                    except OSError:
                        pass
                    watcher.close()
                path.unlink(missing_ok=True)


def engine_info(session):
    """The cleanup engines this service runs. A configured engine that is not loaded yet starts loading, so a caller
    that wants its model waits for it instead of loading a second copy."""
    engines = {id(e): e for e in list(session.cleanup_engines.values()) if e is not None}
    for engine in engines.values():
        if engine.state == 'idle':
            engine.warm()
    return {'engines': [engine.info() for engine in engines.values()]}


def state_snapshot(session, files=None):
    """Text-free state for live frontends: session state, outcome, elapsed time, coarse level."""
    status = session.live_status()
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


class CliContext(namedtuple('CliContext', 'config recovery imports runtime socket request')):
    """What a cli_<name>.py module gets in run(args, context).

    config, recovery, imports and runtime are the paths this invocation resolved from the global options. socket is
    the service socket inside runtime. request(action, identity=None, **fields) sends one command to the running
    service and returns its JSON reply; it raises OSError when the service is absent."""
    __slots__ = ()


def load_cli_modules(directory=None):
    """Import every cli_*.py beside this file (or in `directory`) that has register() and run(). Broken ones are skipped."""
    import importlib.util
    directory = Path(directory) if directory is not None else Path(__file__).resolve().parent
    modules = []
    for source in sorted(directory.glob('cli_*.py')):
        if not source.is_file() or source.is_symlink():
            continue
        name = source.stem
        try:
            spec = importlib.util.spec_from_file_location(name, source)
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
            if not callable(getattr(module, 'register', None)) or not callable(getattr(module, 'run', None)):
                raise ValueError('cli module needs register(subparsers) and run(args, context)')
        except Exception as error:
            sys.modules.pop(name, None)
            print(json.dumps({'error': 'cli_module_unavailable', 'module': name, 'error_class': type(error).__name__}),
                  file=sys.stderr)
            continue
        modules.append(module)
    return modules


def register_cli_modules(commands, modules):
    """Let each module add subcommands. Returns {command name: module} for what it added; core commands are never replaced."""
    owners = {}
    for module in modules:
        before = dict(commands.choices)
        try:
            module.register(commands)
        except Exception as error:
            added = set(commands.choices) - set(before)
            for name in added:
                del commands.choices[name]
            print(json.dumps({'error': 'cli_module_unavailable', 'module': module.__name__,
                              'error_class': type(error).__name__}), file=sys.stderr)
            continue
        for name, parser in list(commands.choices.items()):
            if name in before and parser is not before[name]:
                commands.choices[name] = before[name]
            elif name not in before:
                owners[name] = module
    return owners


def requested_action(tokens, parser, commands):
    """The first command word in argv, skipping global options and their values; None when there isn't one."""
    valued = [option for action in parser._actions if action is not commands for option in action.option_strings
              if action.nargs != 0]
    skip = False
    for token in tokens:
        if skip:
            skip = False
        elif token.startswith('--') and '=' not in token and any(option.startswith(token) for option in valued):
            skip = True
        elif not token.startswith('-'):
            return token
    return None


CLIENT_VERBS = ('start', 'stop', 'toggle', 'cancel', 'status', 'capabilities')


def default_config():
    """The documented config path, else the one setup_speech.py writes, so a prepared install works without --config."""
    preferred = Path.home() / '.config/mouthtype/linux.json'
    prepared = Path.home() / '.local/share/mouthtype/speech-candidate/linux.json'
    return prepared if prepared.is_file() and not preferred.exists() else preferred


def failure_hint(runtime):
    """A path-free next step for the two setup failures every first run can hit, or None."""
    runtime = Path(runtime)
    if not runtime.parent.is_dir() or not os.access(runtime.parent, os.W_OK):
        return 'XDG_RUNTIME_DIR is missing or not writable. Run this from a logged-in graphical session.'
    if not (runtime / 'session.sock').exists():
        return 'The dictation service is not running. Start it with: systemctl --user start mouthtype-linux'
    return None


def unavailable_report(error, runtime):
    report = {'error': 'unavailable', 'error_class': type(error).__name__}
    hint = failure_hint(runtime)
    if hint:
        report['hint'] = hint
    return report


def client_verb(tokens):
    """(verb, runtime directory) when argv is just global path options and one plain socket verb or capabilities, else None.

    Python 3.14's argparse imports dataclasses and inspect when a parser is built, which a hotkey-path client should
    not pay for. Anything this does not recognise goes to the full parser, so behaviour is unchanged."""
    runtime = Path(os.environ.get('XDG_RUNTIME_DIR', '/run/user/' + str(os.getuid()))) / 'mouthtype'
    verb = None
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in ('--config', '--recovery', '--imports') and index + 1 < len(tokens):
            index += 2
        elif token == '--runtime' and index + 1 < len(tokens):
            runtime, index = Path(tokens[index + 1]), index + 2
        elif token.startswith('--runtime='):
            runtime, index = Path(token.split('=', 1)[1]), index + 1
        elif token.startswith(('--config=', '--recovery=', '--imports=')):
            index += 1
        elif token in CLIENT_VERBS and verb is None:
            verb, index = token, index + 1
        else:
            return None
    return (verb, runtime) if verb else None


def main(argv=None, *, cli_directory=None):
    plain = client_verb(sys.argv[1:] if argv is None else list(argv))
    if plain is not None and plain[0] == 'capabilities':
        print(json.dumps(capabilities_report()))
        return 0
    if plain is not None:
        try:
            print(json.dumps(request(plain[1] / 'session.sock', plain[0], None)))
            return 0
        except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
            print(json.dumps(unavailable_report(error, plain[1])), file=sys.stderr)
            return 2
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=default_config())
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
    # Plug-in modules cost an import each, so a core command skips them. A plug-in cannot replace a core command.
    owners = {} if requested_action(sys.argv[1:] if argv is None else list(argv), parser, commands) in commands.choices else \
        register_cli_modules(commands, load_cli_modules(cli_directory))
    args = parser.parse_args(argv)
    path = args.runtime / 'session.sock'
    try:
        if args.action in owners:
            context = CliContext(config=args.config, recovery=args.recovery, imports=args.imports, runtime=args.runtime,
                                 socket=path, request=lambda action, identity=None, **fields: request(path, action, identity, **fields))
            result = owners[args.action].run(args, context)
            return result if type(result) is int else 0
        if args.action == 'capabilities':
            print(json.dumps(capabilities_report()))
            return 0
        if args.action == 'watch':
            halt = threading.Event()
            for event in (signal.SIGINT, signal.SIGTERM):
                signal.signal(event, lambda *_: halt.set())
            return watch(path, sys.stdout, retry=args.retry, stopped=halt)
        if args.action == 'import-result':
            import imports
            sys.stdout.write(imports.result_text(args.imports))
            return 0
        if args.action == 'import-save':
            import imports
            imports.save_text(args.imports, args.path, overwrite=args.overwrite)
            return 0
        if args.action == 'import':
            source = str(Path(args.path).expanduser().resolve())
            print(json.dumps(request(path, 'import', source=source)))
            return 0
        if args.action == 'doctor':
            load_runtime()
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
            for name in ('recording.wav', 'transcript.txt', 'raw-recognition.txt', 'cleanup.json', 'take.json'):
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
        load_runtime()
        verified = hash_cache()
        engine = SpeechEngine(settings, python=config.get('python', sys.executable),
                              request_seconds=config['request_seconds'], hash_cache=verified)
        cleanup_engine = None
        if config['cleanup'] in ('fast', 'thorough'):
            cleanup_path = Path(config['cleanup_engine']).expanduser()
            if not cleanup_path.is_absolute():
                cleanup_path = args.config.resolve().parent / cleanup_path
            cleanup_settings = json.loads(cleanup_path.read_text())['engines'][config['cleanup']]
            cleanup_engine = CleanupEngine(cleanup_settings, hash_cache=verified)
        def load_engine(level):
            if not isinstance(config.get('cleanup_engine'), str) or not config['cleanup_engine']:
                return None
            path = Path(config['cleanup_engine']).expanduser()
            if not path.is_absolute():
                path = args.config.resolve().parent / path
            return CleanupEngine(json.loads(path.read_text())['engines'][level], hash_cache=verified)
        session = Session(PipeWireCapture(config.get('capture_target')), engine,
                          HyprlandDelivery(config['delivery']), args.recovery,
                          maximum_seconds=config['maximum_recording_seconds'],
                          feedback=Notifications(config['notifications']), dictionary=dictionary, phrases=phrases,
                          phrase_clipboard=config.get('phrase_clipboard', False), cleanup=config['cleanup'],
                          cleanup_engine=cleanup_engine, maximum_takes=int(config['maximum_recovery_takes']),
                          audio_days=config['audio_retention_days'], audio_megabytes=config['audio_retention_megabytes'],
                          history_keep=config['history_keep'], styles=config.get('styles'), styles_path=args.config,
                          engine_loader=load_engine, slash_commands=config.get('slash_commands', True))
        files = FileTranscription(engine, args.imports, request_seconds=config['request_seconds'])
        if cleanup_engine is not None and cleanup_engine.state == 'idle':
            cleanup_engine.warm()
        session._notify('ready')
        stopped = threading.Event()
        for event in (signal.SIGINT, signal.SIGTERM):
            signal.signal(event, lambda *_: stopped.set())
        try:
            serve(path, session, stopped, lifetime_seconds=args.lifetime_seconds, files=files,
                  startup=lambda: session.housekeep(force=True),
                  bound=engine.warm)
        finally:
            try:
                files.close()
            finally:
                try:
                    session.close()
                finally:
                    try:
                        engine.stop()
                    finally:
                        try:
                            import transform_host
                            transform_host.stop(args.runtime)
                        finally:
                            for loaded in {id(e): e for e in (cleanup_engine, *list(session.cleanup_engines.values())) if e is not None}.values():
                                loaded.close()
        return 0
    except Exception as error:
        loaded = sys.modules.get('imports')
        if loaded is not None and isinstance(error, loaded.FileError):
            print(json.dumps({'error': error.code}), file=sys.stderr)
            return 2
        if not isinstance(error, (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError)):
            raise
        # Config paths, model errors and transcripts never go into routine diagnostics.
        print(json.dumps(unavailable_report(error, getattr(locals().get('args'), 'runtime', runtime_base / 'mouthtype'))),
              file=sys.stderr)
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
