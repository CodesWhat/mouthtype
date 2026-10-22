"""xdg-desktop-portal client core over jeepney.

Owns one session-bus connection, the app identity registration, the
Request/Response dance, signal subscriptions and portal-restart handling.
Every wait is bounded and close() joins every thread this module starts.
jeepney is imported lazily so Hyprland installs without it keep working.
"""
import logging
import queue
import threading

APP_ID = 'app.mouthtype.Mouthtype'
PORTAL_BUS_NAME = 'org.freedesktop.portal.Desktop'
PORTAL_PATH = '/org/freedesktop/portal/desktop'
REGISTRY_BUS_NAME = PORTAL_BUS_NAME
REGISTRY_PATH = '/org/freedesktop/host/portal/Registry'
REGISTRY_IFACE = 'org.freedesktop.host.portal.Registry'
REQUEST_IFACE = 'org.freedesktop.portal.Request'
SESSION_IFACE = 'org.freedesktop.portal.Session'
DEFAULT_TIMEOUT = 5.0
POLL_INTERVAL = 0.2
# An older portal without the Registry interface answers with one of these.
_REGISTRY_UNSUPPORTED = frozenset({
    'org.freedesktop.DBus.Error.UnknownMethod',
    'org.freedesktop.DBus.Error.UnknownObject',
    'org.freedesktop.DBus.Error.UnknownInterface',
    'org.freedesktop.DBus.Error.ServiceUnknown',
})

log = logging.getLogger('mouthtype.portal')


class PortalError(Exception):
    pass


class PortalUnavailable(PortalError):
    """No session bus, or no portal service on it."""


class PortalTimeout(PortalError, TimeoutError):
    pass


class PortalResponseError(PortalError):
    """The user or the desktop ended a Request with a non-zero response."""

    def __init__(self, code, results=None):
        super().__init__(f'portal request ended with response {code}')
        self.code = code
        self.results = results or {}

    @property
    def cancelled(self):
        return self.code == 1


def sender_token(unique_name):
    """The sender part of a Request path: ':1.42' becomes '1_42'."""
    return unique_name.lstrip(':').replace('.', '_')


def request_path(unique_name, handle_token):
    return f'{PORTAL_PATH}/request/{sender_token(unique_name)}/{handle_token}'


def unwrap_variants(options):
    return {key: value[1] if isinstance(value, tuple) and len(value) == 2 else value for key, value in options.items()}


def _jeepney():
    try:
        import jeepney
        from jeepney.io import threading as jthreading
    except ImportError as exc:
        raise PortalUnavailable('python3-jeepney is not installed') from exc
    return jeepney, jthreading


class Portal:
    def __init__(self, bus='SESSION', app_id=APP_ID, timeout=DEFAULT_TIMEOUT):
        self.bus = bus
        self.app_id = app_id
        self.timeout = timeout
        self._conn = None
        self._router = None
        self._lock = threading.RLock()
        self._tokens = 0
        self._sessions = []
        self._watcher = None
        self._watcher_stop = threading.Event()
        self._closed = False
        self.registered = False

    # connection ---------------------------------------------------------

    def connect(self):
        jeepney, jthreading = _jeepney()
        if self._router is not None:
            return self
        try:
            self._conn = jthreading.open_dbus_connection(bus=self.bus)
        except (OSError, KeyError, TimeoutError, RuntimeError) as exc:
            raise PortalUnavailable(f'cannot reach the session bus: {exc}') from exc
        self._router = jthreading.DBusRouter(self._conn)
        self._closed = False
        return self

    def __enter__(self):
        return self.connect()

    def __exit__(self, *exc):
        self.close()
        return False

    @property
    def unique_name(self):
        self._require()
        return self._conn.unique_name

    def _require(self):
        if self._closed or self._router is None:
            raise PortalError('portal connection is not open')

    def close(self):
        """Stop the watcher, close tracked sessions, then drop the connection."""
        with self._lock:
            if self._router is None:
                return
            watcher, self._watcher = self._watcher, None
        self._watcher_stop.set()
        if watcher is not None and watcher is not threading.current_thread():
            watcher.join(timeout=self.timeout + POLL_INTERVAL)
        for path in list(self._sessions):
            self.close_session(path, timeout=1.0)
        with self._lock:
            router, conn = self._router, self._conn
            self._router = self._conn = None
            self._closed = True
            self.registered = False
        router.close()
        conn.close()

    # calls --------------------------------------------------------------

    def _wait(self, timeout):
        return self.timeout if timeout is None else timeout

    def _send(self, message, timeout):
        self._require()
        try:
            reply = self._router.send_and_get_reply(message, timeout=self._wait(timeout))
        except TimeoutError as exc:
            raise PortalTimeout(f'no reply within {self._wait(timeout)}s') from exc
        except Exception as exc:
            if type(exc).__name__ == 'RouterClosed':
                raise PortalError('portal connection closed') from exc
            raise
        return reply

    def call(self, interface, method, signature='', body=(), *, path=PORTAL_PATH,
             bus_name=PORTAL_BUS_NAME, timeout=None):
        """Call a method and return the reply body, raising PortalError on D-Bus errors."""
        jeepney, _ = _jeepney()
        from jeepney.wrappers import DBusErrorResponse, unwrap_msg
        address = jeepney.DBusAddress(path, bus_name=bus_name, interface=interface)
        reply = self._send(jeepney.new_method_call(address, method, signature, tuple(body)), timeout)
        try:
            return unwrap_msg(reply)
        except DBusErrorResponse as exc:
            raise PortalError(f'{exc.name}: {exc.data}') from exc

    def get_property(self, interface, name, *, path=PORTAL_PATH, timeout=None):
        body = self.call('org.freedesktop.DBus.Properties', 'Get', 'ss', (interface, name),
                         path=path, timeout=timeout)
        return body[0][1]

    def interface_version(self, interface, timeout=None):
        """The portal interface version, or 0 when the portal lacks it."""
        try:
            return int(self.get_property(interface, 'version', timeout=timeout))
        except PortalTimeout:
            raise
        except PortalError:
            return 0

    def register(self, timeout=None):
        """Registry.Register(app_id). False when the portal predates the Registry."""
        jeepney, _ = _jeepney()
        from jeepney.wrappers import DBusErrorResponse, unwrap_msg
        address = jeepney.DBusAddress(REGISTRY_PATH, bus_name=REGISTRY_BUS_NAME, interface=REGISTRY_IFACE)
        message = jeepney.new_method_call(address, 'Register', 'sa{sv}', (self.app_id, {}))
        reply = self._send(message, timeout)
        try:
            unwrap_msg(reply)
        except DBusErrorResponse as exc:
            if exc.name in _REGISTRY_UNSUPPORTED:
                log.warning('portal has no Registry interface; continuing without an app id')
                self.registered = False
                return False
            raise PortalError(f'{exc.name}: {exc.data}') from exc
        self.registered = True
        return True

    # signals ------------------------------------------------------------

    def _match_rule(self, interface, member, path=None, sender=None, arg0=None):
        jeepney, _ = _jeepney()
        rule = jeepney.MatchRule(type='signal', interface=interface, member=member, path=path, sender=sender)
        if arg0 is not None:
            rule.add_arg_condition(0, arg0)
        return rule

    def subscribe(self, interface, member, path=None, *, sender=None, arg0=None, bufsize=64):
        """Context manager yielding a queue.Queue of matching signal messages."""
        return _Subscription(self, self._match_rule(interface, member, path, sender, arg0), bufsize)

    def get_signal(self, signals, timeout=None):
        """Next message from a subscription queue, bounded."""
        try:
            return signals.get(timeout=self._wait(timeout))
        except queue.Empty as exc:
            raise PortalTimeout('no signal within the deadline') from exc

    # requests -----------------------------------------------------------

    def _next_token(self, prefix='mouthtype'):
        with self._lock:
            self._tokens += 1
            return f'{prefix}_{self._tokens}'

    def request(self, interface, method, signature='', args=(), *, options=None,
                path=PORTAL_PATH, timeout=None):
        """Run a portal method that answers through a Request object.

        signature and args exclude the trailing options a{sv}, which we append
        with handle_token added. Returns the Response results with variants unwrapped. Raises
        PortalResponseError for a non-zero response and PortalTimeout when the
        reply or the Response signal misses the deadline.
        """
        jeepney, _ = _jeepney()
        self._require()
        token = self._next_token()
        opts = dict(options or {})
        opts['handle_token'] = ('s', token)
        body = [*args, opts]
        expected = request_path(self._conn.unique_name, token)
        wait = self._wait(timeout)
        with self.subscribe(REQUEST_IFACE, 'Response', expected) as responses:
            handle = self.call(interface, method, signature + 'a{sv}', body, path=path, timeout=wait)[0]
            if handle != expected:
                # Portals older than 0.9 pick their own path: follow it.
                with self.subscribe(REQUEST_IFACE, 'Response', handle) as late:
                    return self._finish_request(late, handle, wait)
            return self._finish_request(responses, handle, wait)

    def _finish_request(self, responses, handle, wait):
        try:
            message = self.get_signal(responses, wait)
        except PortalTimeout:
            self._close_request(handle)
            raise PortalTimeout(f'no Response for {handle} within {wait}s') from None
        code, results = message.body
        results = unwrap_variants(results)
        if code != 0:
            raise PortalResponseError(code, results)
        return results

    def _close_request(self, handle):
        try:
            self.call(REQUEST_IFACE, 'Close', '', (), path=handle, timeout=1.0)
        except PortalError:
            pass

    def create_session(self, interface, options=None, timeout=None):
        """CreateSession on a portal interface. Returns the session handle path."""
        opts = dict(options or {})
        opts['session_handle_token'] = ('s', self._next_token('session'))
        results = self.request(interface, 'CreateSession', options=opts, timeout=timeout)
        session = results.get('session_handle')
        if not session:
            raise PortalError(f'{interface}.CreateSession returned no session_handle')
        with self._lock:
            self._sessions.append(session)
        return session

    def close_session(self, session, timeout=None):
        """Session.Close; a session that is already gone is not an error."""
        with self._lock:
            if session in self._sessions:
                self._sessions.remove(session)
        try:
            self.call(SESSION_IFACE, 'Close', '', (), path=session, timeout=timeout)
        except PortalError as exc:
            log.debug('closing %s: %s', session, exc)

    # restart ------------------------------------------------------------

    def watch_restarts(self, callback):
        """Call callback() after the portal service restarts and we re-registered.

        Sessions die with the old portal, so tracked ones are forgotten. The
        callback runs on the watcher thread, which close() joins.
        """
        self._require()
        with self._lock:
            if self._watcher is not None:
                raise PortalError('restart watcher already running')
            self._watcher_stop.clear()
            ready = threading.Event()
            thread = threading.Thread(target=self._watch, args=(callback, ready),
                                      name='mouthtype-portal-watch', daemon=True)
            self._watcher = thread
        thread.start()
        if not ready.wait(self._wait(None)):
            raise PortalTimeout('restart watcher did not subscribe in time')

    def _watch(self, callback, ready):
        rule = self._match_rule('org.freedesktop.DBus', 'NameOwnerChanged', arg0=PORTAL_BUS_NAME)
        try:
            with _Subscription(self, rule, 16) as changes:
                ready.set()
                while not self._watcher_stop.is_set():
                    try:
                        message = changes.get(timeout=POLL_INTERVAL)
                    except queue.Empty:
                        continue
                    _, _, new_owner = message.body
                    if not new_owner:
                        continue
                    with self._lock:
                        self._sessions.clear()
                    try:
                        self.register()
                        callback()
                    except Exception:
                        log.exception('portal restart handling failed')
        except PortalError:
            log.exception('portal restart watcher stopped')
        finally:
            ready.set()


class _Subscription:
    """AddMatch plus a local filter, undone together."""

    def __init__(self, portal, rule, bufsize):
        self._portal = portal
        self._rule = rule
        self._bufsize = bufsize
        self._handle = None
        self._added = False

    def __enter__(self):
        portal = self._portal
        portal._require()
        from jeepney.bus_messages import message_bus
        self._handle = portal._router.filter(self._rule, queue=queue.Queue(maxsize=self._bufsize))
        try:
            portal._send(message_bus.AddMatch(self._rule), None)
            self._added = True
        except BaseException:
            self._handle.close()
            raise
        return self._handle.queue

    def __exit__(self, *exc):
        portal = self._portal
        self._handle.close()
        if self._added and portal._router is not None:
            from jeepney.bus_messages import message_bus
            try:
                portal._send(message_bus.RemoveMatch(self._rule), 1.0)
            except PortalError:
                pass
        return False
