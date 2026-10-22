"""A jeepney service that implements the portal subset portal.py talks to.

Runs on its own thread against a session bus. Tests drive it through the
attributes below and read `calls` to see what the client sent.
"""
import threading
import time

PORTAL_BUS_NAME = 'org.freedesktop.portal.Desktop'
REGISTRY_IFACE = 'org.freedesktop.host.portal.Registry'
REQUEST_IFACE = 'org.freedesktop.portal.Request'
SESSION_IFACE = 'org.freedesktop.portal.Session'
SHORTCUTS_IFACE = 'org.freedesktop.portal.GlobalShortcuts'
REMOTE_IFACE = 'org.freedesktop.portal.RemoteDesktop'
CLIPBOARD_IFACE = 'org.freedesktop.portal.Clipboard'
PROPERTIES_IFACE = 'org.freedesktop.DBus.Properties'
POLL = 0.05


def unwrap(options):
    return {key: value[1] for key, value in options.items()}


def _sender_token(sender):
    return sender.lstrip(':').replace('.', '_')


class FakePortal:
    def __init__(self, bus_address, versions=None):
        self.bus_address = bus_address
        self.versions = dict(versions or {SHORTCUTS_IFACE: 2})
        self.calls = []
        self.registered_apps = []
        self.registry_error = None
        self.silent = set()
        self.response_codes = {}
        self.response_delay = 0.0
        self.sessions = set()
        self.devices_granted = 1
        self.selected = {}
        self.grant_counter = 0
        self.valid_grants = set()
        self.deny_new_grants = False
        self._conn = None
        self._thread = None
        self._stop = threading.Event()
        self._send_lock = threading.Lock()

    # lifecycle ----------------------------------------------------------

    def start(self):
        from jeepney.bus_messages import DBus, DBusNameFlags
        from jeepney.io.blocking import open_dbus_connection, Proxy
        self._conn = open_dbus_connection(bus=self.bus_address)
        reply = Proxy(DBus(), self._conn, timeout=5).RequestName(PORTAL_BUS_NAME, DBusNameFlags.do_not_queue)
        if reply[0] != 1:
            self._conn.close()
            self._conn = None
            raise RuntimeError(f'could not own {PORTAL_BUS_NAME}: {reply}')
        self._stop.clear()
        self._thread = threading.Thread(target=self._serve, name='fake-portal', daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None
        if self._conn is not None:
            self._conn.close()
            self._conn = None

    def restart(self):
        """Drop the name and take it again, like xdg-desktop-portal restarting."""
        self.stop()
        self.sessions.clear()
        self.start()

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
        return False

    # server loop --------------------------------------------------------

    def _serve(self):
        from jeepney import MessageType
        while not self._stop.is_set():
            try:
                message = self._conn.receive(timeout=POLL)
            except TimeoutError:
                continue
            except (OSError, ValueError):
                return
            if message.header.message_type is MessageType.method_call:
                try:
                    self._handle(message)
                except (OSError, ValueError):
                    return

    def _send(self, message):
        with self._send_lock:
            self._conn.send(message)

    def _handle(self, message):
        from jeepney import HeaderFields, new_error, new_method_return
        fields = message.header.fields
        interface = fields.get(HeaderFields.interface, '')
        member = fields[HeaderFields.member]
        path = fields[HeaderFields.path]
        sender = fields.get(HeaderFields.sender, '')
        self.calls.append((interface, member, path, message.body))
        if interface == REGISTRY_IFACE and member == 'Register':
            if self.registry_error:
                self._send(new_error(message, self.registry_error, 's', ('registry unavailable',)))
                return
            self.registered_apps.append(message.body[0])
            self._send(new_method_return(message))
        elif interface == PROPERTIES_IFACE and member == 'Get':
            target, name = message.body
            if name == 'version' and target in self.versions:
                self._send(new_method_return(message, 'v', (('u', self.versions[target]),)))
            else:
                self._send(new_error(message, 'org.freedesktop.DBus.Error.UnknownProperty', 's', (name,)))
        elif interface == SESSION_IFACE and member == 'Close':
            self.sessions.discard(path)
            self._send(new_method_return(message))
        elif interface == REQUEST_IFACE and member == 'Close':
            self._send(new_method_return(message))
        elif interface == SHORTCUTS_IFACE and member in ('CreateSession', 'BindShortcuts'):
            self._request(message, sender, member, interface)
        elif interface == REMOTE_IFACE and member in ('CreateSession', 'SelectDevices', 'Start'):
            self._request(message, sender, member, interface)
        elif interface == CLIPBOARD_IFACE and member == 'RequestClipboard':
            self._send(new_method_return(message))
        else:
            self._send(new_error(message, 'org.freedesktop.DBus.Error.UnknownMethod', 's', (member,)))

    def _request(self, message, sender, member, interface=SHORTCUTS_IFACE):
        from jeepney import new_method_return
        options = message.body[-1]
        token = options['handle_token'][1]
        handle = f'/org/freedesktop/portal/desktop/request/{_sender_token(sender)}/{token}'
        self._send(new_method_return(message, 'o', (handle,)))
        if member in self.silent:
            return
        code = self.response_codes.get(member, 0)
        if (interface == REMOTE_IFACE and member == 'Start' and self.deny_new_grants
                and self.selected.get(message.body[0], {}).get('restore_token') not in self.valid_grants):
            code = 1
        results = {}
        if code == 0 and member == 'CreateSession':
            session = f'/org/freedesktop/portal/desktop/session/{_sender_token(sender)}/{options["session_handle_token"][1]}'
            self.sessions.add(session)
            results = {'session_handle': ('s', session)}
        elif code == 0 and interface == REMOTE_IFACE and member == 'Start':
            # A stored grant that is still valid skips the dialog and keeps its key. A new grant is minted.
            wanted = self.selected.get(message.body[0], {}).get('restore_token')
            if wanted not in self.valid_grants:
                self.grant_counter += 1
                wanted = f'grant-{self.grant_counter}'
                self.valid_grants.add(wanted)
            results = {'devices': ('u', self.devices_granted), 'clipboard_enabled': ('b', True),
                       'restore_token': ('s', wanted), 'persist_mode': ('u', 2)}
        elif code == 0 and interface == REMOTE_IFACE:
            if member == 'SelectDevices':
                self.selected[message.body[0]] = unwrap(options)
        elif code == 0:
            results = {'shortcuts': ('a(sa{sv})', [(sid, props) for sid, props in message.body[1]])}
        if self.response_delay:
            time.sleep(self.response_delay)
        self._emit(handle, REQUEST_IFACE, 'Response', 'ua{sv}', (code, results), destination=sender)

    def _emit(self, path, interface, member, signature, body, destination=None):
        from jeepney import DBusAddress, HeaderFields, new_signal
        signal = new_signal(DBusAddress(path, interface=interface), member, signature, body)
        if destination:
            signal.header.fields[HeaderFields.destination] = destination
        self._send(signal)

    # test drivers -------------------------------------------------------

    def emit_activated(self, session, shortcut_id, timestamp=0, destination=None):
        self._emit('/org/freedesktop/portal/desktop', SHORTCUTS_IFACE, 'Activated', 'osta{sv}',
                   (session, shortcut_id, timestamp, {}), destination=destination)

    def emit_session_closed(self, session, destination=None):
        self._emit(session, SESSION_IFACE, 'Closed', 'a{sv}', ({},), destination=destination)
