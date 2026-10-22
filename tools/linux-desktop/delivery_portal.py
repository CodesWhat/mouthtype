"""RemoteDesktop session and grant store for portal delivery (GNOME and KDE).

Keyboard-only RemoteDesktop session with persist_mode 2. The portal hands back a restore value on Start, which we
keep in portal.json (0600) so later runs start without a prompt. We never prompt in the middle of a take: start()
only calls the portal without a stored grant when the caller says it is interactive. A refused or revoked grant
leaves the backend in 'needs_grant', which callers treat as recover-only.
"""
import json
import logging
import os
import tempfile
import threading
from pathlib import Path

import portal as portal_mod

REMOTE_IFACE = 'org.freedesktop.portal.RemoteDesktop'
CLIPBOARD_IFACE = 'org.freedesktop.portal.Clipboard'
DEVICE_KEYBOARD = 1
PERSIST_UNTIL_REVOKED = 2
# Start can sit behind a consent dialog, so it gets longer than an ordinary call.
START_TIMEOUT = 120.0

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
