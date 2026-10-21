"""Transform Selection backend: capture the selected text once, preview an edit, write it back only to the same window.

Source is the Wayland primary selection, falling back to the clipboard (decision D11). Clean up is the Basic cleanup
with no model. Fix grammar, Make shorter, More formal and More casual run the Thorough llama.cpp model with the Mac's
one-instruction prompts (transform_worker.py). Writing back goes through HyprlandDelivery, the same guarded path
dictation uses, and is refused when the focused window is no longer the one the text came from.

A capture lives in a private file under the runtime directory (tmpfs on a normal session) for ten minutes, so the
separate processes behind a panel session can share it. Nothing is written to the state or config directories.
"""

from difflib import SequenceMatcher
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

from cleanup import BasicCleanup
from vendor.grapheme import graphemes

INTERFACE = 1
MAX_UNITS = 16000
DIFF_LIMIT = 2000
CAPTURE_SECONDS = 600
FOCUS_WAIT_SECONDS = 1.5
LOAD_SECONDS = 120
SOURCE_BYTES = 64000
ID_PATTERN = re.compile('[0-9a-f]{32}')
MODEL_LEVEL = 'thorough'
MODEL_NAME = 'Thorough'

KINDS = (
    {'id': 'clean-up', 'title': 'Clean up', 'model': False,
     'description': 'Spoken commands and spacing. No model.'},
    {'id': 'fix-grammar', 'title': 'Fix grammar', 'model': True,
     'description': 'Spelling, punctuation and capitalization. Keeps your wording.'},
    {'id': 'make-shorter', 'title': 'Make shorter', 'model': True,
     'description': 'Cuts words that add nothing. Keeps every fact.'},
    {'id': 'more-formal', 'title': 'More formal', 'model': True,
     'description': 'Professional register: no slang, no contractions.'},
    {'id': 'more-casual', 'title': 'More casual', 'model': True,
     'description': 'Conversational register with contractions.'},
)
KIND_IDS = tuple(kind['id'] for kind in KINDS)

BUSY = 'Finish the current dictation or file job first.'
NOTHING_SELECTED = ("Select up to 16,000 characters of text, then try again. Apps that don't set the primary "
                    "selection need the text copied first.")


def _desktop():
    """The running desktop module. Loaded as __main__ by the CLI, so importing it again would build a second copy."""
    for name in ('desktop', '__main__'):
        module = sys.modules.get(name)
        if module is not None and hasattr(module, 'CleanupEngine') and hasattr(module, 'HyprlandDelivery'):
            return module
    import desktop
    return desktop


def units(text):
    """Length in UTF-16 code units, the Mac's 16,000 limit."""
    return len(text.encode('utf-16-le', 'surrogatepass')) // 2


def restore_boundary_whitespace(original, result):
    """Cleanup and the model trim their output, so put the selection's own leading and trailing whitespace back."""
    lead = original[:len(original) - len(original.lstrip())]
    trail = original[len(original.rstrip()):]
    return lead + result.strip() + trail


def app_name(target):
    """A short label for the window class: the last segment of a reverse-DNS class, otherwise the class itself."""
    name = target.get('class', '') if isinstance(target, dict) else ''
    return name.rsplit('.', 1)[-1] if '.' in name.strip('.') else name


def app_summary(target):
    if not isinstance(target, dict):
        return None
    return {'class': target.get('class'), 'name': app_name(target), 'pid': target.get('pid'),
            'address': target.get('address')}


# ---- model output clean-up, ported from TextTransform.sanitize --------------------------------------------------

_PREAMBLE = re.compile(
    r"^(?:(?:sure|certainly|of course|okay|ok)[,!.]?\s+)?(?:here(?:'s|’s| is| are)[ \t]+(?:(?:the|a|an|your)[ \t]+)?"
    r"(?:[a-z-]+[ \t]+){0,3}(?:text|version|rewrite|result|output|translation|summary|draft|revision|edit)"
    r"(?:[ \t]+(?:(?:of|for)[ \t]+(?:your|the)[ \t]+(?:selected[ \t]+)?(?:text|selection)|"
    r"(?:in|with)[ \t]+(?:an?[ \t]+)?[a-z-]+[ \t]+tone))?|"
    r"(?:the )?(?:corrected|edited|revised|rewritten|updated) (?:text|version)):[ \t]*(?:\n\s*|\s+)", re.I)
_FENCE_OPEN = re.compile(r'^```[A-Za-z0-9_+.-]*$')


def _enclosed(text, source, opening, closing):
    if (len(text) < len(opening) + len(closing) or not text.startswith(opening) or not text.endswith(closing) or
            source.startswith(opening) or source.endswith(closing)):
        return None
    inner = text[len(opening):len(text) - len(closing)]
    return None if opening in inner or closing in inner else inner


def _unfenced(text, source):
    if (not text.startswith('```') or not text.endswith('```') or source.startswith('```') or
            source.endswith('```')):
        return None
    lines = text.split('\n')
    if len(lines) < 3 or lines[-1].strip() != '```' or not _FENCE_OPEN.match(lines[0]):
        return None
    inner = '\n'.join(lines[1:-1])
    return None if '```' in inner else inner


def _unwrap_once(text, source):
    inner = _unfenced(text, source)
    if inner is not None:
        return inner
    for name in ('text', 'transcript'):
        inner = _enclosed(text, source, '<%s>' % name, '</%s>' % name)
        if inner is not None:
            return inner
    for opening, closing in (('"', '"'), ('“', '”')):
        inner = _enclosed(text, source, opening, closing)
        if inner is not None:
            return inner
    match = _PREAMBLE.search(text)
    if match is None:
        return text
    lead = match.group(0).strip().lower()
    if source.lower().startswith(lead) or match.end() >= len(text):
        return text
    return text[match.end():]


def sanitize_output(output, source=''):
    """Trim the output and peel framing the model added around all of it. Markup inside the text is never touched."""
    source = source.strip()
    text = output.strip()
    for _ in range(4):
        following = _unwrap_once(text, source).strip()
        if following == text:
            break
        text = following
    return text


def implausibly_long(output, source):
    """A transform's output more than four times the input plus 200 characters is not an edit of it."""
    return len(output) > len(source) * 4 + 200


# ---- diff segments ----------------------------------------------------------------------------------------------

def _pieces(text):
    """Words, whitespace runs and single other grapheme clusters, so a combining mark is never split from its base."""
    result, previous = [], None
    for cluster in graphemes(text):
        first = cluster[0]
        kind = 'w' if first.isalnum() or first == '_' else 's' if first.isspace() else 'o'
        if kind != 'o' and previous == kind:
            result[-1] += cluster
        else:
            result.append(cluster)
        previous = kind
    return result


def _merge(segments):
    merged = []
    for kind, text in segments:
        if not text:
            continue
        if merged and merged[-1]['kind'] == kind:
            merged[-1]['text'] += text
        else:
            merged.append({'text': text, 'kind': kind})
    return merged


def diff_segments(original, result):
    """Segments for the panel to render. Original marks removed text (strike it through), result marks added text
    (highlight it). Pieces are compared by their exact UTF-8 bytes: no case folding or Unicode normalisation.
    Either side over DIFF_LIMIT characters returns one unmarked segment per side and highlight false."""
    if len(original) > DIFF_LIMIT or len(result) > DIFF_LIMIT:
        return {'highlight': False, 'reason': 'over_limit', 'limit': DIFF_LIMIT,
                'original': _merge([('equal', original)]), 'result': _merge([('equal', result)])}
    old, new = _pieces(original), _pieces(result)
    matcher = SequenceMatcher(None, [piece.encode('utf-8') for piece in old],
                              [piece.encode('utf-8') for piece in new], autojunk=False)
    before, after = [], []
    for tag, a, b, c, d in matcher.get_opcodes():
        if tag == 'equal':
            before.append(('equal', ''.join(old[a:b])))
            after.append(('equal', ''.join(new[c:d])))
        else:
            before.append(('removed', ''.join(old[a:b])))
            after.append(('added', ''.join(new[c:d])))
    return {'highlight': True, 'reason': None, 'limit': DIFF_LIMIT, 'original': _merge(before), 'result': _merge(after)}


# ---- capture store ----------------------------------------------------------------------------------------------

class CaptureStore:
    """One private JSON file per capture in the runtime directory. Expired and replaced captures are deleted."""

    def __init__(self, runtime, clock=time.time):
        self.runtime, self.clock = Path(runtime), clock

    def _directory(self):
        self.runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = self.runtime.stat()
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Runtime directory must be owned by you with mode 0700')
        return self.runtime

    def path(self, identity):
        if not isinstance(identity, str) or not ID_PATTERN.fullmatch(identity):
            raise ValueError('Invalid transform id')
        return self.runtime / ('transform-%s.json' % identity)

    def clear(self):
        if not self.runtime.is_dir():
            return
        for path in self.runtime.glob('transform-*.json'):
            path.unlink(missing_ok=True)

    def save(self, record):
        directory = self._directory()
        descriptor, temporary = tempfile.mkstemp(prefix='.transform-', dir=directory)
        try:
            with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
                json.dump(record, stream, ensure_ascii=False)
            os.replace(temporary, self.path(record['id']))
        except BaseException:
            Path(temporary).unlink(missing_ok=True)
            raise

    def load(self, identity):
        path = self.path(identity)
        try:
            if path.is_symlink():
                return None
            record = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            return None
        if (not isinstance(record, dict) or record.get('id') != identity or
                type(record.get('expires')) not in (int, float) or not isinstance(record.get('text'), str)):
            return None
        if record['expires'] <= self.clock():
            self.delete(identity)
            return None
        return record

    def delete(self, identity):
        self.path(identity).unlink(missing_ok=True)


class Deadline:
    """Sets `cancelled` when the time is up. `expired` tells a timeout apart from a user cancel."""

    def __init__(self, cancelled, seconds):
        self.cancelled, self.expired = cancelled, False
        self.timer = threading.Timer(seconds, self._fire)
        self.timer.daemon = True

    def _fire(self):
        self.expired = True
        self.cancelled.set()

    def __enter__(self):
        self.timer.start()
        return self

    def __exit__(self, *exc):
        self.timer.cancel()


def failure(code, message, **fields):
    return {'state': 'error', 'error': code, 'message': message, **fields}


class SelectionError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


class TransformService:
    """The five verbs behind `transform`. Each returns the JSON-serialisable dict the panel renders."""

    def __init__(self, config, runtime, *, busy=None, cancelled=None, clock=time.time, run=None, worker=None,
                 focus_wait=FOCUS_WAIT_SECONDS, load_seconds=LOAD_SECONDS, deadline_seconds=None):
        self.config, self.runtime = Path(config), Path(runtime)
        self.busy = busy or (lambda: False)
        self.cancelled = cancelled if cancelled is not None else threading.Event()
        self.clock = clock
        self.run = run or subprocess.run
        self.worker = worker
        self.focus_wait, self.load_seconds, self.deadline_seconds = focus_wait, load_seconds, deadline_seconds
        self.store = CaptureStore(self.runtime, clock)

    # -- model status

    def _settings(self):
        """(state, reason, engine settings). State is ready, absent, unconfigured, unsupported or unreadable."""
        unconfigured = ('unconfigured', 'AI transforms need the %s cleanup model. Set it up with setup_cleanup.py '
                        '--level thorough, then try again.' % MODEL_NAME, None)
        try:
            config = _desktop().validate_config(json.loads(self.config.read_text()))
            engine = config.get('cleanup_engine')
            if not isinstance(engine, str) or not engine:
                return unconfigured
            path = Path(engine).expanduser()
            if not path.is_absolute():
                path = self.config.resolve().parent / path
            settings = json.loads(path.read_text())['engines'].get(MODEL_LEVEL)
            if settings is None:
                return unconfigured
            _desktop().CleanupEngine(settings)
        except FileNotFoundError:
            return ('unreadable', "Mouthtype's settings or cleanup model settings are missing.", None)
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            return ('unreadable', "The cleanup model settings couldn't be read.", None)
        if settings.get('prompt', 's1') != 'shared':
            return ('unsupported', "%s can't run text transforms." % MODEL_NAME, None)
        files = [Path(item['path']) for item in settings['artifacts'].values()] + [Path(settings['server'])]
        if not all(item.is_file() for item in files):
            return ('absent', 'AI transforms need the %s cleanup model, and its files are missing. Run '
                    'setup_cleanup.py --level thorough, then try again.' % MODEL_NAME, None)
        return ('ready', None, settings)

    def status(self):
        state, reason, _ = self._settings()
        kinds = [{'id': kind['id'], 'title': kind['title'], 'description': kind['description'],
                  'needs_model': kind['model'], 'available': not kind['model'] or state == 'ready',
                  'reason': reason if kind['model'] and state != 'ready' else None} for kind in KINDS]
        return {'state': 'status', 'interface': INTERFACE, 'kinds': kinds,
                'model': {'level': MODEL_LEVEL, 'name': MODEL_NAME, 'state': state, 'reason': reason},
                'limits': {'source_units': MAX_UNITS, 'diff_characters': DIFF_LIMIT,
                           'capture_seconds': CAPTURE_SECONDS}}

    # -- capture

    def _window(self):
        return _desktop().HyprlandDelivery({'mode': 'paste'}, run=self.run).snapshot()

    def _read(self, source):
        """The selection's text from one source, or None when it holds no text. Raises SelectionError."""
        desktop = _desktop()
        flags = ['--primary'] if source == 'primary' else []
        try:
            listing = self.run(['wl-paste', *flags, '--list-types'], capture_output=True, text=True, check=False,
                               timeout=1)
        except FileNotFoundError:
            raise SelectionError('wl_clipboard_missing', 'Install wl-clipboard (wl-paste) to read the selection.')
        except (OSError, subprocess.SubprocessError):
            return None
        if getattr(listing, 'returncode', 1) != 0 or not isinstance(listing.stdout, str):
            return None
        types = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
        if any(item in desktop.HyprlandDelivery.SENSITIVE_TYPES for item in types):
            raise SelectionError('sensitive', 'That selection is marked private by a password manager, so Mouthtype '
                                              "won't read it.")
        if not any(item.startswith('text/') or item in desktop.HyprlandDelivery.TEXT_TYPES for item in types):
            return None
        try:
            text = desktop.read_phrase_clipboard(['wl-paste', *flags, '--no-newline', '--type', 'text'], seconds=2,
                                                 maximum=SOURCE_BYTES)
        except desktop.ClipboardTooLarge:
            raise SelectionError('too_long', 'Select up to 16,000 characters.')
        except (OSError, ValueError, desktop.PhraseContextUnavailable, subprocess.SubprocessError):
            return None
        return text if text.strip() else None

    def capture(self):
        if self.busy():
            return failure('busy', BUSY)
        # The text and the window must belong together, so focus is read on both sides of the read.
        before = self._window()
        try:
            text, source = None, 'primary'
            for source in ('primary', 'clipboard'):
                if self.cancelled.is_set():
                    return {'state': 'cancelled'}
                text = self._read(source)
                if text is not None:
                    break
        except SelectionError as error:
            return failure(error.code, error.message)
        if text is None:
            return failure('nothing_selected', NOTHING_SELECTED)
        if units(text) > MAX_UNITS:
            return failure('too_long', 'Select up to 16,000 characters.')
        target = self._window()
        if target != before:
            return failure('focus_changed', 'The focused window changed while the selection was read. Select the '
                           'text again.')
        self.store.clear()
        record = {'id': uuid.uuid4().hex, 'created': self.clock(), 'expires': self.clock() + CAPTURE_SECONDS,
                  'source': source, 'text': text, 'target': target, 'result': None, 'kind': None, 'submitted': False}
        self.store.save(record)
        return {'state': 'captured', 'id': record['id'], 'source': source, 'fallback': source == 'clipboard',
                'app': app_summary(target), 'text': text, 'units': units(text), 'expires_in': CAPTURE_SECONDS}

    def _record(self, identity):
        try:
            record = self.store.load(identity)
        except ValueError:
            return None, failure('no_capture', 'That selection is no longer captured. Select the text again.')
        if record is None:
            return None, failure('no_capture', 'That selection is no longer captured. Select the text again.')
        return record, None

    # -- transform

    def _model(self, kind, text, settings):
        """Model text, or None when interrupted. Raises RuntimeError, ValueError or OSError on a model fault."""
        desktop = _desktop()
        words = len(text.split())
        seconds = min(180.0, 5.0 + 0.4 * words)

        class Engine(desktop.CleanupEngine):
            def _prime(self):
                pass

            def load(self, cancelled):
                with self.lock:
                    self._ensure_loaded(cancelled)

        engine = Engine(settings, worker=self.worker or Path(__file__).with_name('transform_worker.py'),
                        startup_seconds=self.load_seconds)
        box = {}

        def work():
            try:
                engine.load(self.cancelled)
                box['text'] = engine.clean(text, self.cancelled, seconds=seconds, controls=kind)
            except BaseException as error:
                box['error'] = error

        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        while thread.is_alive() and not self.cancelled.is_set():
            thread.join(.05)
        if thread.is_alive():
            # A load can sit in a hash or a worker read. Let it finish in the background; the process exit stops it.
            engine.shutdown.set()
            threading.Thread(target=engine.close, daemon=True).start()
            return None
        engine.close()
        if 'error' in box:
            if self.cancelled.is_set():
                return None
            raise box['error']
        return box['text']

    def transform(self, identity, kind):
        record, problem = self._record(identity)
        if problem:
            return problem
        entry = next((item for item in KINDS if item['id'] == kind), None)
        if entry is None:
            return failure('unknown_transform', 'Unknown transform. Choose one of: ' + ', '.join(KIND_IDS) + '.')
        settings = None
        if entry['model']:
            state, reason, settings = self._settings()
            if state != 'ready':
                return {'state': 'unavailable', 'id': identity, 'kind': kind, 'reason': reason}
        original = record['text']
        started = time.monotonic()
        budget = 10.0 if settings is None else self.load_seconds + min(180.0, 5.0 + 0.4 * len(original.split())) + 5.0
        if self.deadline_seconds is not None:
            budget = self.deadline_seconds
        title = entry['title']
        with Deadline(self.cancelled, budget) as deadline:
            try:
                if settings is None:
                    text = BasicCleanup('basic').apply(original).strip()
                    if not text:
                        return failure('empty_result', 'Basic cleanup left nothing. Pick a transform or cancel.')
                else:
                    produced = self._model(kind, original, settings)
                    if produced is None:
                        # No cancel and no deadline means the model's own request budget ran out.
                        if deadline.expired or not self.cancelled.is_set():
                            return {'state': 'timeout', 'id': identity, 'kind': kind,
                                    'message': '%s took too long on the local model. Retry, or cancel.' % title}
                        return {'state': 'cancelled', 'id': identity, 'kind': kind}
                    text = sanitize_output(produced, original)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, _desktop().Stopped):
                if self.cancelled.is_set():
                    if deadline.expired:
                        return {'state': 'timeout', 'id': identity, 'kind': kind,
                                'message': '%s took too long on the local model. Retry, or cancel.' % title}
                    return {'state': 'cancelled', 'id': identity, 'kind': kind}
                if settings is None:
                    return failure('cleanup_failed', 'Basic cleanup could not run on that text.')
                return failure('model_failed', '%s failed on the local model. Retry, or cancel.' % title)
        if not text:
            return failure('empty_result', 'The model returned nothing. Retry, pick another transform, or cancel.')
        if implausibly_long(text, original):
            return failure('result_too_long', '%s returned far more text than the selection, so the result '
                           "can't be used. Retry, or cancel." % title)
        if units(text) > MAX_UNITS:
            return failure('result_too_long', 'The result is over 16,000 characters. Retry or cancel.')
        record.update(result=text, kind=kind, submitted=False)
        self.store.save(record)
        return {'state': 'ready', 'id': identity, 'kind': kind, 'title': title, 'model': entry['model'],
                'text': text, 'original': original, 'changed': text.encode('utf-8') != original.encode('utf-8'),
                'diff': diff_segments(original, text), 'app': app_summary(record.get('target')),
                'source': record['source'], 'elapsed_ms': int((time.monotonic() - started) * 1000),
                'message': ('Basic cleanup preview. Review it before accepting. Names and numbers are not rewritten.'
                            if settings is None else
                            '%s preview from the local model. Review and edit it before accepting.' % title)}

    # -- write back

    def _result_text(self, record, edited):
        text = edited if edited is not None else record.get('result')
        if not isinstance(text, str) or not text.strip() or units(text) > MAX_UNITS:
            return None
        return text

    def _refuse(self, identity, reason, message, record):
        return {'state': 'refused', 'id': identity, 'reason': reason, 'message': message,
                'app': app_summary(record.get('target')), 'primary_action': 'copy-result',
                'offer': ['copy-result']}

    def accept(self, identity, edited=None):
        record, problem = self._record(identity)
        if problem:
            return problem
        text = self._result_text(record, edited)
        if text is None:
            return failure('nothing_to_accept', 'There is no result to accept. Run a transform first.')
        target = record.get('target')
        name = app_name(target) or 'the app'
        if self.busy():
            return self._refuse(identity, 'busy', BUSY + ' You can copy the result.', record)
        if not isinstance(target, dict):
            return self._refuse(identity, 'window_unknown', "Mouthtype couldn't tell which window the text came "
                                'from, so it won\'t write back. Copy the result instead.', record)
        try:
            delivery_config = _desktop().validate_config(json.loads(self.config.read_text()))['delivery']
        except (OSError, ValueError, KeyError, TypeError):
            return failure('config_unreadable', "Mouthtype's settings couldn't be read.")
        delivery = _desktop().HyprlandDelivery(delivery_config, run=self.run)
        if delivery_config.get('mode') not in ('type', 'paste'):
            return self._refuse(identity, 'delivery_disabled', 'Automatic replacement is off (delivery mode is '
                                'recover). Copy the result instead.', record)
        if not delivery.allowed(target):
            return self._refuse(identity, 'delivery_not_allowed', "Delivery isn't allowed for %s in Mouthtype's "
                                'settings. Copy the result instead.' % name, record)
        # The panel gives focus back to the app as it closes; allow it a moment before judging the window changed.
        end = time.monotonic() + self.focus_wait
        while delivery.snapshot() != target:
            if self.cancelled.is_set():
                return {'state': 'cancelled', 'id': identity}
            if time.monotonic() >= end:
                return self._refuse(identity, 'window_changed', 'The focused window changed since the selection was '
                                    "captured, so Mouthtype won't write into %s. Copy the result instead." % name,
                                    record)
            time.sleep(.05)
        replacement = restore_boundary_whitespace(record['text'], text)
        with Deadline(self.cancelled, 30.0) as deadline:
            outcome = delivery.submit(replacement, target, cancelled=self.cancelled)
            # The earlier clipboard is put back on a daemon thread; this process must not exit before it has run.
            restoring = delivery.restore_thread
            if restoring is not None:
                restoring.join(float(delivery_config.get('restore_delay_seconds', delivery.restore_delay_seconds)) + 6)
        if outcome == 'target_changed':
            return self._refuse(identity, 'window_changed', 'The focused window changed since the selection was '
                                "captured, so Mouthtype won't write into %s. Copy the result instead." % name, record)
        if outcome == 'unsupported_text':
            return self._refuse(identity, 'unsupported_text', "The result has control characters, or line breaks for "
                                "a terminal, that can't be sent safely. Copy the result instead.", record)
        if outcome == 'recover_only':
            return self._refuse(identity, 'clipboard_not_restorable', 'Your clipboard holds something Mouthtype '
                                "can't put back after pasting, so it didn't paste. Copy the result instead.", record)
        if outcome == 'not_attempted':
            return {'state': 'timeout' if deadline.expired else 'cancelled', 'id': identity}
        record.update(result=text, submitted=True)
        self.store.save(record)
        return {'state': 'requested', 'id': identity, 'app': app_summary(target), 'outcome': outcome,
                'message': 'Replacement requested. Check the original field. To undo, press Ctrl-Z in that app, or '
                           'copy the original text from here.'}

    def copy(self, identity, *, original=False, edited=None):
        record, problem = self._record(identity)
        if problem:
            return problem
        text = record['text'] if original else self._result_text(record, edited)
        if text is None:
            return failure('nothing_to_copy', 'There is no result to copy. Run a transform first.')
        try:
            self.run(['wl-copy', '--type', 'text/plain;charset=utf-8'], input=text.encode('utf-8'),
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=5)
        except FileNotFoundError:
            return failure('wl_clipboard_missing', 'Install wl-clipboard (wl-copy) to copy.')
        except (OSError, subprocess.SubprocessError):
            return failure('copy_failed', "Mouthtype couldn't copy to the clipboard.")
        return {'state': 'copied', 'id': identity, 'what': 'original' if original else 'result'}

    def cancel(self, identity=None):
        if identity is None:
            self.store.clear()
        else:
            try:
                self.store.delete(identity)
            except ValueError:
                return failure('no_capture', 'Invalid capture id.')
        return {'state': 'discarded'}
