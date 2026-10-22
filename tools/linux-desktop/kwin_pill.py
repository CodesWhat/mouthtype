"""Watch KWin for the pill's layer-shell surface during the KDE acceptance run.

KWin scripts cannot write files, and a layer-shell surface does not show up in workspace.windowList(), so a script
loaded through org.kde.kwin.Scripting subscribes to windowAdded and windowRemoved and reports each window to a
D-Bus name this module owns. gi is imported lazily, so nothing here costs a host without it anything.
"""
import json
import subprocess
import threading
import time

BUS_NAME = 'org.mouthtype.Probe'
INTERFACE = 'org.mouthtype.Probe'
SCRIPT_NAME = 'mouthtype-acceptance-pill'
# KWin's Layer enum: OnScreenDisplayLayer, which is where a layer-shell overlay surface lands.
OVERLAY_LAYER = 9
SCRIPT = """
function report(kind, window) {
  callDBus('%(name)s', '/', '%(interface)s', 'report', JSON.stringify({
    kind: kind, caption: window.caption, resourceClass: window.resourceClass, layer: window.layer,
    skipTaskbar: window.skipTaskbar, x: window.x, y: window.y, width: window.width, height: window.height}));
}
workspace.windowAdded.connect(function (window) { report('added', window); });
workspace.windowRemoved.connect(function (window) { report('removed', window); });
""" % {'name': BUS_NAME, 'interface': INTERFACE}
INTROSPECTION = ('<node><interface name="%s"><method name="report"><arg type="s" direction="in"/></method>'
                 '</interface></node>' % INTERFACE)


def is_pill(event):
    """A mapped or unmapped overlay surface that stays out of the task bar, which is what the pill sets up."""
    return event.get('layer') == OVERLAY_LAYER and bool(event.get('skipTaskbar'))


def pill_result(events, pressed_at, released_at, screen, tolerance=3):
    """Check the events KWin reported around a held chord. The pill must map between press and release, sit
    bottom-centre of screen (width, height) and unmap afterwards. Returns the evidence dict, raises ValueError."""
    pills = [event for event in events if is_pill(event)]
    added = [event for event in pills if event['kind'] == 'added']
    if not added:
        raise ValueError('No layer-shell overlay surface mapped: ' + json.dumps(events))
    first = added[0]
    if not pressed_at <= first['at'] <= released_at:
        raise ValueError('The pill mapped outside the held chord: ' + json.dumps(
            {'pill_at': first['at'], 'pressed_at': pressed_at, 'released_at': released_at}))
    width, height = screen
    centre = first['x'] + first['width'] / 2
    if abs(centre - width / 2) > tolerance:
        raise ValueError('The pill is not horizontally centred: ' + json.dumps(first))
    bottom = first['y'] + first['height']
    if not height - 40 <= bottom <= height:
        raise ValueError('The pill is not at the bottom edge: ' + json.dumps(first))
    unmapped = any(event['kind'] == 'removed' and event['at'] >= first['at'] for event in pills)
    return {'mapped': True, 'layer': 'overlay', 'geometry': [first['x'], first['y'], first['width'], first['height']],
            'during_hold': True, 'unmapped_after': unmapped}


class KwinWatcher:
    """Owns BUS_NAME, loads SCRIPT into the running KWin and collects what it reports as events with an 'at' time.
    call(argv) runs a command and returns its stdout text."""

    def __init__(self, directory, call, clock=time.monotonic):
        self.directory, self.call, self.clock = directory, call, clock
        self.events = []
        self._lock = threading.Lock()
        self._ready = threading.Event()
        self._loop = None
        self._thread = None
        self._loaded = False

    def snapshot(self):
        with self._lock:
            return list(self.events)

    def _receive(self, text):
        try:
            event = json.loads(text)
        except ValueError:
            return
        event['at'] = self.clock()
        with self._lock:
            self.events.append(event)

    def _serve(self):
        import gi
        gi.require_version('Gio', '2.0')
        from gi.repository import Gio, GLib
        node = Gio.DBusNodeInfo.new_for_xml(INTROSPECTION)

        def method(connection, sender, path, interface, name, parameters, invocation):
            self._receive(parameters.unpack()[0])
            invocation.return_value(None)

        def acquired(connection, name):
            connection.register_object('/', node.interfaces[0], method, None, None)

        Gio.bus_own_name(Gio.BusType.SESSION, BUS_NAME, Gio.BusNameOwnerFlags.NONE, acquired,
                         lambda connection, name: self._ready.set(), None)
        self._loop = GLib.MainLoop()
        self._loop.run()

    def start(self):
        self._thread = threading.Thread(target=self._serve, name='kwin-watcher', daemon=True)
        self._thread.start()
        if not self._ready.wait(10):
            raise ValueError('Could not own ' + BUS_NAME + ' on the session bus')
        path = self.directory / 'kwin-pill.js'
        path.write_text(SCRIPT)
        scripting = ['gdbus', 'call', '--session', '--dest', 'org.kde.KWin', '--object-path', '/Scripting']
        self.call(scripting + ['--method', 'org.kde.kwin.Scripting.loadScript', str(path), SCRIPT_NAME])
        self._loaded = True
        self.call(scripting + ['--method', 'org.kde.kwin.Scripting.start'])

    def stop(self):
        if self._loaded:
            self._loaded = False
            try:
                self.call(['gdbus', 'call', '--session', '--dest', 'org.kde.KWin', '--object-path', '/Scripting',
                           '--method', 'org.kde.kwin.Scripting.unloadScript', SCRIPT_NAME])
            except (OSError, subprocess.SubprocessError):
                pass
        if self._loop is not None:
            self._loop.quit()
            self._thread.join(5)
            self._loop = None
