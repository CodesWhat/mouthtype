"""RemoteDesktop session and grant store for portal delivery (GNOME and KDE).

Keyboard-only RemoteDesktop session with persist_mode 2. The portal hands back a restore value on Start, which we
keep in portal.json (0600) so later runs start without a prompt. We never prompt in the middle of a take: start()
only calls the portal without a stored grant when the caller says it is interactive. A refused or revoked grant
leaves the backend in 'needs_grant', which callers treat as recover-only.

PortalClipboard sits on top of an active session: multi-MIME SetSelection (with the concealed-copy hint when
asked), a bounded read of the previous selection, and a restore that only runs while we still own the selection.

PortalDelivery is the Delivery for GNOME and KDE: paste = portal clipboard plus a keysym paste chord, type = short
single-line text as keysyms with a paste fallback. Keysyms rather than keycodes keep it correct on any layout.
"""
import json
import logging
import os
import queue
import select
import tempfile
import time
import threading
from pathlib import Path

import portal as portal_mod

REMOTE_IFACE = 'org.freedesktop.portal.RemoteDesktop'
CLIPBOARD_IFACE = 'org.freedesktop.portal.Clipboard'
DEVICE_KEYBOARD = 1
PERSIST_UNTIL_REVOKED = 2
# Start can sit behind a consent dialog, so it gets longer than an ordinary call.
START_TIMEOUT = 120.0

TEXT_MIMES = ('text/plain;charset=utf-8', 'text/plain')
CONCEALED_MIME = 'x-kde-passwordManagerHint'
CONCEALED_VALUE = b'secret'
READ_CAP = 1024 * 1024
READ_DEADLINE = 1.0
WRITE_DEADLINE = 2.0
MAX_PREVIOUS_TYPES = 8
OWNER_CONFIRM_TIMEOUT = 1.0
POLL = 0.1

log = logging.getLogger('mouthtype.delivery_portal')


def grant_store_path(environ=None):
    environ = os.environ if environ is None else environ
    base = Path(environ.get('XDG_STATE_HOME') or Path.home() / '.local/state')
    return base / 'mouthtype' / 'portal.json'


class GrantStore:
    """portal.json: the RemoteDesktop restore value, written atomically with mode 0600."""

    def __init__(self, path):
        self.path = Path(path)

    def load(self):
        try:
            data = json.loads(self.path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            return None
        grant = data.get('remote_desktop_grant') if isinstance(data, dict) else None
        return grant if isinstance(grant, str) and grant else None

    def save(self, grant):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp = tempfile.mkstemp(dir=self.path.parent, prefix='.portal-', suffix='.tmp')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as handle:
                json.dump({'remote_desktop_grant': grant}, handle)
            os.chmod(temp, 0o600)
            os.replace(temp, self.path)
        except BaseException:
            try:
                os.unlink(temp)
            except OSError:
                pass
            raise

    def clear(self):
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


class RemoteDesktopSession:
    """Owns one keyboard-only RemoteDesktop session on a connected, registered Portal.

    status is one of: idle (not started), active, needs_grant (no usable grant, recover-only), unavailable
    (the portal has no RemoteDesktop, or errored). detail carries a short reason for the UI.
    """

    def __init__(self, portal, store, clipboard=True, start_timeout=START_TIMEOUT):
        self.portal = portal
        self.store = store
        self.clipboard = clipboard
        self.start_timeout = start_timeout
        self.session = None
        self.status = 'idle'
        self.detail = ''
        self._lock = threading.RLock()
        self._closed_signals = None
        self._closed_subscription = None

    def snapshot(self):
        return {'status': self.status, 'detail': self.detail, 'session': self.session,
                'stored_grant': self.store.load() is not None}

    @property
    def active(self):
        return self.session is not None and not self._session_lost() and self.status == 'active'

    def start(self, interactive=False):
        """Open the session. Without a stored grant and interactive=False this makes no portal call at all,
        so a take can never trigger a prompt. Returns the status."""
        with self._lock:
            if self.session is not None:
                self._drop()
            stored = self.store.load()
            if stored is None and not interactive:
                return self._set('needs_grant', 'no stored keyboard grant')
            if self.portal.interface_version(REMOTE_IFACE) < 1:
                return self._set('unavailable', 'portal has no RemoteDesktop interface')
            try:
                return self._open(stored)
            except portal_mod.PortalResponseError as exc:
                self._drop()
                if stored is not None:
                    self.store.clear()
                reason = 'keyboard grant was cancelled' if exc.cancelled else 'keyboard grant was refused'
                return self._set('needs_grant', reason)
            except portal_mod.PortalError as exc:
                self._drop()
                return self._set('unavailable', str(exc))

    def _open(self, stored):
        portal = self.portal
        session = portal.create_session(REMOTE_IFACE)
        self.session = session
        self._watch_closed(session)
        options = {'types': ('u', DEVICE_KEYBOARD), 'persist_mode': ('u', PERSIST_UNTIL_REVOKED)}
        if stored is not None:
            options['restore_token'] = ('s', stored)
        portal.request(REMOTE_IFACE, 'SelectDevices', 'o', (session,), options=options)
        if self.clipboard:
            portal.call(CLIPBOARD_IFACE, 'RequestClipboard', 'oa{sv}', (session, {}))
        results = portal.request(REMOTE_IFACE, 'Start', 'os', (session, ''), timeout=self.start_timeout)
        if not int(results.get('devices', 0)) & DEVICE_KEYBOARD:
            self._drop()
            if stored is not None:
                self.store.clear()
            return self._set('needs_grant', 'keyboard access was not granted')
        grant = results.get('restore_token')
        if grant:
            self.store.save(grant)
        return self._set('active', '')

    def _set(self, status, detail):
        self.status, self.detail = status, detail
        return status

    # session loss -------------------------------------------------------

    def _watch_closed(self, session):
        subscription = self.portal.subscribe(portal_mod.SESSION_IFACE, 'Closed', session)
        self._closed_signals = subscription.__enter__()
        self._closed_subscription = subscription

    def _unwatch_closed(self):
        subscription, self._closed_subscription = self._closed_subscription, None
        self._closed_signals = None
        if subscription is not None:
            subscription.__exit__(None, None, None)

    def _session_lost(self):
        """True once the desktop closed the session under us. Marks needs_grant: the grant was revoked."""
        signals = self._closed_signals
        if signals is None or signals.empty():
            return False
        with self._lock:
            self._drop(close=False)
            self._set('needs_grant', 'the desktop closed the keyboard session')
        return True

    def check(self):
        """Poll for a desktop-side close. Returns the current status."""
        self._session_lost()
        return self.status

    def revoked(self):
        """The grant is gone for good (user revoked it): forget it so the next interactive start asks again."""
        with self._lock:
            self.store.clear()
            self._drop()
            return self._set('needs_grant', 'keyboard grant was revoked')

    def on_portal_restart(self):
        """Sessions die with the portal. Drop ours and reconnect from the stored grant, never interactively."""
        with self._lock:
            self._drop(close=False)
            return self.start(interactive=False)

    def _drop(self, close=True):
        self._unwatch_closed()
        session, self.session = self.session, None
        if session is not None and close:
            self.portal.close_session(session, timeout=1.0)

    def close(self):
        with self._lock:
            self._drop()
            if self.status == 'active':
                self._set('idle', '')



def _read_fd(fd, cap, deadline):
    """Read a pipe to EOF. None when it exceeds cap bytes or misses the deadline; the fd is always closed."""
    raw = fd.to_raw_fd()
    chunks, size = [], 0
    end = time.monotonic() + deadline
    try:
        while True:
            left = end - time.monotonic()
            if left <= 0 or not select.select([raw], [], [], left)[0]:
                return None
            chunk = os.read(raw, 65536)
            if not chunk:
                return b''.join(chunks)
            size += len(chunk)
            if size > cap:
                return None
            chunks.append(chunk)
    except OSError:
        return None
    finally:
        os.close(raw)


def _write_fd(fd, data, deadline):
    """Write all of data to a pipe within the deadline. False when the reader stalls or goes away."""
    raw = fd.to_raw_fd()
    view = memoryview(data)
    end = time.monotonic() + deadline
    try:
        os.set_blocking(raw, False)
        while view:
            left = end - time.monotonic()
            if left <= 0 or not select.select([], [raw], [], left)[1]:
                return False
            try:
                view = view[os.write(raw, view):]
            except BlockingIOError:
                continue
        return True
    except OSError:
        return False
    finally:
        os.close(raw)


class ClipboardCopy:
    """What copy() hands back: the selection that was there before, and which of our offers this is."""

    def __init__(self, generation, previous):
        self.generation = generation
        self.previous = previous  # mime type -> bytes, possibly empty


class PortalClipboard:
    """Clipboard portal operations bound to one active RemoteDesktopSession.

    A background thread answers SelectionTransfer for whatever we offered and tracks SelectionOwnerChanged, so a
    restore can tell whether someone else copied after us. Bound to the session it was started on: after a
    session loss, close() it and build a new one from the new session.
    """

    def __init__(self, remote, read_cap=READ_CAP, read_deadline=READ_DEADLINE, write_deadline=WRITE_DEADLINE,
                 owner_timeout=OWNER_CONFIRM_TIMEOUT):
        self.remote = remote
        self.portal = remote.portal
        self.read_cap = read_cap
        self.read_deadline = read_deadline
        self.write_deadline = write_deadline
        self.owner_timeout = owner_timeout
        self._lock = threading.RLock()
        self._session = None
        self._offers = {}
        self._generation = 0
        self._owner_mimes = []
        self._lost = False
        self._confirmed = threading.Event()
        self._subscription = None
        self._signals = None
        self._thread = None
        self._stop = threading.Event()

    # lifecycle ----------------------------------------------------------

    def start(self):
        with self._lock:
            if self._thread is not None:
                return self
            if not self.remote.active:
                raise portal_mod.PortalError('clipboard needs an active RemoteDesktop session')
            self._session = self.remote.session
            self._subscription = self.portal.subscribe(CLIPBOARD_IFACE, None, portal_mod.PORTAL_PATH, bufsize=128)
            self._signals = self._subscription.__enter__()
            self._stop.clear()
            self._thread = threading.Thread(target=self._serve, name='mouthtype-portal-clipboard', daemon=True)
            self._thread.start()
        return self

    def close(self):
        with self._lock:
            thread, self._thread = self._thread, None
            subscription, self._subscription = self._subscription, None
            self._offers = {}
        self._stop.set()
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=self.write_deadline + 1.0)
        if subscription is not None:
            subscription.__exit__(None, None, None)

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.close()
        return False

    # signals ------------------------------------------------------------

    def _serve(self):
        from jeepney import HeaderFields
        while not self._stop.is_set():
            try:
                message = self._signals.get(timeout=POLL)
            except queue.Empty:
                continue
            body = message.body
            if not body or body[0] != self._session:
                continue
            member = message.header.fields.get(HeaderFields.member)
            try:
                if member == 'SelectionOwnerChanged':
                    self._owner_changed(portal_mod.unwrap_variants(body[1]))
                elif member == 'SelectionTransfer':
                    self._transfer(body[1], body[2])
            except portal_mod.PortalError as exc:
                log.debug('clipboard %s: %s', member, exc)
            except Exception:
                log.exception('clipboard signal handling failed')

    def _owner_changed(self, options):
        with self._lock:
            if options.get('session_is_owner'):
                self._confirmed.set()
                return
            self._owner_mimes = list(options.get('mime_types') or [])
            if self._offers:
                self._lost = True
                self._offers = {}

    def _transfer(self, mime, serial):
        with self._lock:
            data = self._offers.get(mime)
        session = self._session
        if data is None:
            self.portal.call(CLIPBOARD_IFACE, 'SelectionWriteDone', 'oub', (session, serial, False))
            return
        fd = self.portal.call(CLIPBOARD_IFACE, 'SelectionWrite', 'ou', (session, serial))[0]
        ok = _write_fd(fd, data, self.write_deadline)
        self.portal.call(CLIPBOARD_IFACE, 'SelectionWriteDone', 'oub', (session, serial, ok))

    # operations ---------------------------------------------------------

    def read_current(self):
        """The selection other apps hold, as {mime: bytes}. Types over the size cap or the deadline are left
        out, so a partial value is never restored. Empty when nothing is known to be on the clipboard."""
        with self._lock:
            mimes = list(self._owner_mimes)[:MAX_PREVIOUS_TYPES]
            owned = bool(self._offers)
        if owned:
            return {}
        found = {}
        for mime in mimes:
            try:
                fd = self.portal.call(CLIPBOARD_IFACE, 'SelectionRead', 'os', (self._session, mime), timeout=1.0)[0]
            except portal_mod.PortalError:
                continue
            data = _read_fd(fd, self.read_cap, self.read_deadline)
            if data is not None:
                found[mime] = data
        return found

    def offer(self, offers):
        """Take the selection with {mime: bytes}. Returns the generation that identifies this offer."""
        if not offers:
            raise ValueError('nothing to offer')
        with self._lock:
            self._generation += 1
            generation = self._generation
            self._offers = {mime: bytes(data) for mime, data in offers.items()}
            self._lost = False
            self._confirmed.clear()
        self.portal.call(CLIPBOARD_IFACE, 'SetSelection', 'oa{sv}',
                         (self._session, {'mime_types': ('as', list(offers))}))
        if not self._confirmed.wait(self.owner_timeout):
            log.debug('no SelectionOwnerChanged for our own selection; assuming we own it')
        return generation

    def copy(self, text, concealed=False):
        """Put text on the clipboard, optionally with the concealed-copy hint. The returned ClipboardCopy
        carries the previous selection for restore()."""
        previous = self.read_current()
        data = text.encode('utf-8')
        offers = {mime: data for mime in TEXT_MIMES}
        if concealed:
            offers[CONCEALED_MIME] = CONCEALED_VALUE
        return ClipboardCopy(self.offer(offers), previous)

    def owns(self, generation):
        with self._lock:
            return generation == self._generation and bool(self._offers) and not self._lost

    def restore(self, copy):
        """Put the previous selection back, but only while this copy is still the selection. False when someone
        else copied since, when there was nothing readable to restore, or when the call failed."""
        with self._lock:
            if not self.owns(copy.generation) or not copy.previous:
                return False
        try:
            self.offer(copy.previous)
        except portal_mod.PortalError as exc:
            log.debug('restoring the clipboard: %s', exc)
            return False
        return True


# Keysyms. Latin-1 keysyms equal their code point; everything else is 0x01000000 + code point.
KEYSYM_RETURN = 0xFF0D
KEYSYM_TAB = 0xFF09
KEYSYM_CONTROL_L = 0xFFE3
KEYSYM_SHIFT_L = 0xFFE1
KEYSYM_V = 0x76
TYPE_MAX_CHARS = 200
RESTORE_DELAY = 1.5
SENSITIVE_TYPES = (CONCEALED_MIME,)


def keysym_for(char):
    """The X11 keysym for one character, or None when it is a control character with no keysym."""
    code = ord(char)
    if char == '\n':
        return KEYSYM_RETURN
    if char == '\t':
        return KEYSYM_TAB
    if code < 0x20 or 0x7F <= code <= 0x9F:
        return None
    if code <= 0xFF:
        return code
    return 0x01000000 + code


class PortalKeyboard:
    """NotifyKeyboardKeysym on an active RemoteDesktop session. Raises PortalError on any failed send."""

    def __init__(self, remote):
        self.remote = remote

    def key(self, keysym, down):
        if not self.remote.active:
            raise portal_mod.PortalError('keyboard session is not active')
        self.remote.portal.call(REMOTE_IFACE, 'NotifyKeyboardKeysym', 'oa{sv}iu',
                                (self.remote.session, {}, keysym, 1 if down else 0), timeout=2.0)

    def tap(self, keysym):
        self.key(keysym, True)
        self.key(keysym, False)

    def chord(self, modifiers, keysym):
        """Hold modifiers, tap keysym, release in reverse. Modifiers are released even when the tap fails."""
        pressed = []
        try:
            for modifier in modifiers:
                self.key(modifier, True)
                pressed.append(modifier)
            self.tap(keysym)
        finally:
            for modifier in reversed(pressed):
                try:
                    self.key(modifier, False)
                except portal_mod.PortalError:
                    pass


class PortalDelivery:
    """Delivery on portal desktops. Same submit/paste signatures and outcome strings as HyprlandDelivery.

    targets supplies snapshot(), is_terminal(target) (the AT-SPI target, P4). Without one the target is
    {'class': 'unknown'} and nothing is a terminal, which only passes allowed() under any_window.
    """

    def __init__(self, config, remote, clipboard, keyboard=None, targets=None):
        self.config = config
        self.remote = remote
        self.clipboard = clipboard
        self.keyboard = keyboard or PortalKeyboard(remote)
        self.targets = targets
        self.restore_thread = None

    def snapshot(self):
        if self.targets is not None:
            return self.targets.snapshot()
        return {'class': 'unknown'}

    def is_terminal(self, target):
        return bool(self.targets.is_terminal(target)) if self.targets is not None else False

    def allowed(self, target):
        if (self.config.get('mode') not in ('type', 'paste') or
                self.config.get('allow_unknown_secure_field') is not True or not target):
            return False
        if self.config.get('any_window') is True:
            return True
        return target.get('class') in self.config.get('allowed_classes', [])

    def _ready(self):
        self.remote.check()
        return self.remote.active

    def submit(self, text, target, cancelled=None, verified=False):
        if not self.allowed(target) or not self._ready():
            return 'recover_only'
        if cancelled is not None and cancelled.is_set():
            return 'not_attempted'
        if self.config.get('mode') == 'type':
            outcome = self.type_text(text, target, cancelled)
            if outcome != 'fallback':
                return outcome
        return self.paste(text, target, cancelled, verified)

    def type_text(self, text, target, cancelled=None):
        """Type short single-line text as keysyms. Returns 'fallback' when paste should be used instead."""
        keysyms = []
        for char in text:
            if char in '\r\n':
                return 'fallback'
            keysym = keysym_for(char)
            if keysym is None:
                return 'unsupported_text'
            keysyms.append(keysym)
        if not keysyms:
            return 'unknown'
        if len(keysyms) > self.config.get('type_max_chars', TYPE_MAX_CHARS):
            return 'fallback'
        if self.snapshot() != target:
            return 'target_changed'
        if cancelled is not None and cancelled.is_set():
            return 'not_attempted'
        sent = 0
        try:
            for keysym in keysyms:
                self.keyboard.tap(keysym)
                sent += 1
        except portal_mod.PortalError:
            # Nothing typed yet is safe to paste instead; a partial prefix must never be replayed.
            return 'fallback' if sent == 0 else 'unknown'
        return 'unknown'

    def paste(self, text, target, cancelled=None, verified=False):
        """Clipboard plus a paste chord. Line breaks and tabs travel as text; other controls are refused."""
        if not self._ready():
            return 'recover_only'
        terminal = self.is_terminal(target)
        if terminal:
            text = text.rstrip('\r\n')
        if any((ord(char) < 32 and char not in '\n\t') or 127 <= ord(char) <= 159 for char in text):
            return 'unsupported_text'
        if terminal and ('\n' in text or '\r' in text) and self.config.get('allow_terminal_multiline') is not True:
            return 'unsupported_text'
        if not verified and self.snapshot() != target:
            return 'target_changed'
        if cancelled is not None and cancelled.is_set():
            return 'not_attempted'
        copy = None
        try:
            copy = self.clipboard.copy(text)
            if self.snapshot() != target:
                return 'target_changed'
            if cancelled is not None and cancelled.is_set():
                return 'not_attempted'
            modifiers = (KEYSYM_CONTROL_L, KEYSYM_SHIFT_L) if terminal else (KEYSYM_CONTROL_L,)
            self.keyboard.chord(modifiers, KEYSYM_V)
        except portal_mod.PortalError:
            # The chord may have landed; a second one could paste twice.
            return 'unknown'
        finally:
            if copy is not None and self.config.get('restore_clipboard', True):
                self.schedule_restore(copy)
        return 'unknown'

    def schedule_restore(self, copy, *, delay=None):
        """Put the earlier selection back once the target has read ours. PortalClipboard.restore skips it when
        someone else copied since, and a password-manager selection is never put back (it would republish it)."""
        if not copy.previous or any(mime in SENSITIVE_TYPES for mime in copy.previous):
            return
        if delay is None:
            delay = self.config.get('restore_delay_seconds', RESTORE_DELAY)

        def restore():
            time.sleep(delay)
            try:
                self.clipboard.restore(copy)
            except Exception:
                log.exception('clipboard restore failed')

        thread = threading.Thread(target=restore, name='mouthtype-portal-restore', daemon=True)
        self.restore_thread = thread
        thread.start()
