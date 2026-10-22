"""GlobalShortcuts portal backend: desktop shortcuts drive Session.command.

Registers four actions (dictate-hold, dictate-toggle, cancel, transform-open) on one portal session, reads back what
the desktop actually granted, and turns Activated and Deactivated signals into session commands. Hold mode keeps the
safety nets the Mac has: a lost session, a portal restart, a missing Deactivated or a stuck key all end the take.
Signal timestamps are relative milliseconds, so nothing here compares them to a wall clock.
"""
import logging
import queue
import subprocess
import threading
import time

import backends
import portal as portal_module

SHORTCUTS_IFACE = 'org.freedesktop.portal.GlobalShortcuts'
SESSION_IFACE = 'org.freedesktop.portal.Session'
HOLD, TOGGLE, CANCEL, TRANSFORM = 'dictate-hold', 'dictate-toggle', 'cancel', 'transform-open'
ACTIONS = (
    (HOLD, 'Dictate while held', 'CTRL+ALT+M'),
    (TOGGLE, 'Start or stop dictation', 'CTRL+ALT+SPACE'),
    (CANCEL, 'Cancel the current take', 'CTRL+ALT+ESCAPE'),
    (TRANSFORM, 'Transform the selected text', 'CTRL+ALT+R'),
)
POLL_INTERVAL = 0.1
# A press with no Deactivated for a non-hold action stops counting as held after this long.
REPEAT_WINDOW = 5.0

log = logging.getLogger('mouthtype.shortcuts')


class ShortcutsUnavailable(RuntimeError):
    """No usable GlobalShortcuts portal, or the user refused the bind."""


class PortalShortcuts:
    def __init__(self, session, *, portal_factory=portal_module.Portal, bus='SESSION', preferred=None,
                 on_transform_open=None, clock=time.monotonic):
        self.session = session
        self.portal_factory = portal_factory
        self.bus = bus
        self.preferred = {sid: trigger for sid, _, trigger in ACTIONS}
        self.preferred.update(preferred or {})
        self.on_transform_open = on_transform_open
        self.clock = clock
        self.state = 'stopped'
        self.error = None
        self.version = 0
        self.granted = {}
        self._portal = None
        self._handle = None
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread = None
        self._pressed = {}
        self._hold_deadline = None

    # lifecycle ----------------------------------------------------------

    def start(self):
        """Connect, register the app id, bind the actions and start dispatching. Raises ShortcutsUnavailable."""
        if self._thread is not None:
            raise ShortcutsUnavailable('shortcuts already started')
        try:
            self._portal = self.portal_factory(bus=self.bus).connect()
            self._portal.register()
            self.version = self._portal.interface_version(SHORTCUTS_IFACE)
            if self.version < 1:
                raise ShortcutsUnavailable('the desktop portal has no GlobalShortcuts interface')
            self._bind()
            self._portal.watch_restarts(self._restarted)
        except portal_module.PortalError as exc:
            self._fail('portal_unavailable')
            self._close_portal()
            raise ShortcutsUnavailable(str(exc)) from exc
        except ShortcutsUnavailable:
            self._fail('portal_unavailable')
            self._close_portal()
            raise
        self._stop.clear()
        ready = threading.Event()
        self._thread = threading.Thread(target=self._run, args=(ready,), name='mouthtype-shortcuts', daemon=True)
        self._thread.start()
        if not ready.wait(5):
            self.stop()
            raise ShortcutsUnavailable('shortcut listener did not start')
        self._publish()
        return self

    def stop(self):
        self._stop.set()
        thread, self._thread = self._thread, None
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=5)
        self._end_hold('stopped')
        self._close_portal()
        self.state = 'stopped'
        self._publish()

    def _close_portal(self):
        portal, self._portal = self._portal, None
        if portal is not None:
            portal.close()

    def _fail(self, error):
        self.state, self.error = 'failed', error
        self._publish()

    def _bind(self):
        portal = self._portal
        handle = portal.create_session(SHORTCUTS_IFACE)
        shortcuts = [(sid, {'description': ('s', description), 'preferred_trigger': ('s', self.preferred[sid])})
                     for sid, description, _ in ACTIONS]
        try:
            results = portal.request(SHORTCUTS_IFACE, 'BindShortcuts', 'oa(sa{sv})s', (handle, shortcuts, ''), timeout=60)
        except portal_module.PortalResponseError as exc:
            portal.close_session(handle)
            raise ShortcutsUnavailable('shortcut binding was refused' if exc.cancelled else str(exc)) from exc
        granted = {}
        for sid, props in results.get('shortcuts', []):
            description = props.get('trigger_description')
            if isinstance(description, tuple):
                description = description[1]
            granted[sid] = description or ''
        with self._lock:
            self._handle, self.granted = handle, granted
            self.state, self.error = 'bound', None

    # status -------------------------------------------------------------

    def status(self):
        """Granted triggers as the desktop reported them, never the preference."""
        with self._lock:
            return {'backend': 'portal', 'state': self.state, 'error': self.error, 'version': self.version,
                    'triggers': dict(self.granted), 'hold': self._hold_deadline is not None}

    def configure(self, timeout=5.0):
        """Open the desktop's own shortcut editor for this app. Needs a bound v2 portal session."""
        with self._lock:
            handle, portal, version = self._handle, self._portal, self.version
        if portal is None or handle is None or self.state != 'bound':
            raise ShortcutsUnavailable('no bound shortcut session')
        if version < 2:
            raise ShortcutsUnavailable('the desktop portal cannot open its shortcut settings (needs version 2)')
        try:
            portal.call(SHORTCUTS_IFACE, 'ConfigureShortcuts', 'osa{sv}', (handle, '', {}), timeout=timeout)
        except portal_module.PortalError as exc:
            raise ShortcutsUnavailable(str(exc)) from exc

    def _publish(self):
        if hasattr(self.session, 'shortcuts_status'):
            self.session.shortcuts_status = self.status()

    # dispatch -----------------------------------------------------------

    def _run(self, ready):
        from jeepney import HeaderFields
        portal = self._portal
        try:
            with portal.subscribe(SHORTCUTS_IFACE, None) as signals, \
                    portal.subscribe(SESSION_IFACE, 'Closed') as closed:
                ready.set()
                while not self._stop.is_set():
                    try:
                        message = signals.get(timeout=POLL_INTERVAL)
                    except queue.Empty:
                        message = None
                    if message is not None:
                        self._signal(message)
                    try:
                        gone = closed.get_nowait()
                    except queue.Empty:
                        gone = None
                    if gone is not None and gone.header.fields.get(HeaderFields.path) == self._handle:
                        self._session_lost()
                    self._check_hold()
        except portal_module.PortalError:
            log.exception('shortcut listener stopped')
            self._end_hold('listener_stopped')
            self._fail('listener_stopped')
        finally:
            ready.set()

    def _signal(self, message):
        from jeepney import HeaderFields
        member = message.header.fields.get(HeaderFields.member)
        if member not in ('Activated', 'Deactivated') or len(message.body) < 2:
            return
        handle, shortcut_id = message.body[0], message.body[1]
        with self._lock:
            if handle != self._handle:
                return
        if member == 'Activated':
            self._activated(shortcut_id)
        else:
            self._deactivated(shortcut_id)

    def _activated(self, shortcut_id):
        now = self.clock()
        with self._lock:
            seen = self._pressed.get(shortcut_id)
            if seen is not None and (shortcut_id == HOLD or now - seen < REPEAT_WINDOW):
                return  # key repeat, or a lost release; hold is bounded by its deadline instead
            self._pressed[shortcut_id] = now
        if shortcut_id == HOLD:
            was_idle = getattr(self.session, 'state', 'idle') == 'idle'
            status = self.session.command('start')
            if was_idle and status.get('state') == 'recording':
                with self._lock:
                    self._hold_deadline = now + float(getattr(self.session, 'maximum_seconds', 60))
        elif shortcut_id == TOGGLE:
            self.session.command('toggle')
        elif shortcut_id == CANCEL:
            self.session.command('cancel')
        elif shortcut_id == TRANSFORM:
            if self.on_transform_open is not None:
                self.on_transform_open()
            else:
                log.info('transform-open pressed with no handler')

    def _deactivated(self, shortcut_id):
        with self._lock:
            self._pressed.pop(shortcut_id, None)
        if shortcut_id == HOLD:
            self._end_hold('released')

    def _end_hold(self, reason):
        with self._lock:
            held, self._hold_deadline = self._hold_deadline is not None, None
            self._pressed.pop(HOLD, None)
        if held and getattr(self.session, 'state', None) == 'recording':
            log.info('ending held take: %s', reason)
            self.session.command('stop')

    def _check_hold(self):
        with self._lock:
            overdue = self._hold_deadline is not None and self.clock() >= self._hold_deadline
        if overdue:
            self._end_hold('maximum duration')

    def _session_lost(self):
        self._end_hold('session closed')
        with self._lock:
            self._handle, self.granted = None, {}
            self.state, self.error = 'lost', 'session_closed'
        self._publish()

    def _restarted(self):
        """The portal service restarted: sessions are gone, so bind again on the new one."""
        self._end_hold('portal restarted')
        with self._lock:
            self._handle, self.granted = None, {}
            self.state = 'rebinding'
        self._publish()
        try:
            self._bind()
        except (portal_module.PortalError, ShortcutsUnavailable) as exc:
            log.warning('rebinding after a portal restart failed: %s', exc)
            with self._lock:
                self._handle, self.granted = None, {}
                self.state, self.error = 'lost', 'rebind_failed'
        self._publish()


def _make(session, config=None, **kwargs):
    return PortalShortcuts(session, **kwargs)


backends.register_shortcuts('portal', _make)


def attach(session, env, override='auto'):
    """Start the portal shortcut backend when the environment and desktop.shortcuts select it. Returns it, or None.

    A missing or refusing portal is not fatal: the daemon keeps serving and the reason shows in status."""
    if backends.shortcuts_name(backends.detect(env), override) != 'portal':
        return None
    shortcuts = backends.make_shortcuts('portal', session)
    try:
        return shortcuts.start()
    except ShortcutsUnavailable as exc:
        log.warning('portal shortcuts unavailable: %s', exc)
        return None


NO_SHORTCUTS = {'backend': 'none', 'state': 'unavailable', 'error': None, 'version': 0, 'triggers': {}, 'hold': False}


def status_of(shortcuts):
    """The shortcut status the daemon reports, with the same keys whether or not a portal backend is running."""
    return shortcuts.status() if shortcuts is not None else dict(NO_SHORTCUTS)


def _open_settings(opener, argv):
    process = opener(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    threading.Thread(target=process.wait, name='mouthtype-settings-reaper', daemon=True).start()


def configure(shortcuts, env, *, opener=subprocess.Popen):
    """Send the user to the desktop's shortcut editor and return the status plus how it was opened.

    A v2 portal opens its own editor for our bound session. Otherwise GNOME gets Settings > Keyboard, which is where
    its custom shortcuts live. Anything else reports configure_unavailable rather than guessing at a settings app."""
    status = status_of(shortcuts)
    reason = None
    if shortcuts is not None:
        try:
            shortcuts.configure()
            return {**status_of(shortcuts), 'method': 'portal'}
        except ShortcutsUnavailable as exc:
            reason = str(exc)
    if backends.detect(env) == 'gnome':
        try:
            _open_settings(opener, ['gnome-control-center', 'keyboard'])
            return {**status, 'method': 'gnome-control-center'}
        except OSError as exc:
            reason = 'gnome-control-center did not start: ' + str(exc)
    return {**status, 'method': None, 'error': 'configure_unavailable', 'reason': reason}
