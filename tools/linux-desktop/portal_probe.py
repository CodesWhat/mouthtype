#!/usr/bin/env python3
"""Probe the xdg-desktop-portal on a live GNOME or KDE session and print evidence JSON.

Records the portal interface versions (GlobalShortcuts, RemoteDesktop, Clipboard, host Registry), then binds a
chord, presses and releases it through an input driver, and logs when Activated and Deactivated arrive. The
Deactivated latency decides the hold-versus-toggle default for the desktop shortcut backend.

Drivers (--driver): mutter (the direct org.gnome.Mutter.RemoteDesktop API, GNOME), portal (the RemoteDesktop
portal, keyboard only, KDE once the app is authorized), none (versions only), auto (by XDG_CURRENT_DESKTOP).
Every stage records its own error and the probe still prints JSON, so a missing consent dialog shows up as
evidence rather than a crash. Exit 0 when JSON was printed, 2 when the session bus or portal is unreachable.
"""
import argparse
import json
import os
import sys
import time

import portal as portal_mod

INTERFACES = {
    'GlobalShortcuts': 'org.freedesktop.portal.GlobalShortcuts',
    'RemoteDesktop': 'org.freedesktop.portal.RemoteDesktop',
    'Clipboard': 'org.freedesktop.portal.Clipboard',
}
SHORTCUTS_IFACE = INTERFACES['GlobalShortcuts']
REMOTE_IFACE = INTERFACES['RemoteDesktop']
SHORTCUT_ID = 'probe-chord'
# CTRL+ALT+m as X11 keysyms: Control_L, Alt_L, m.
CHORD_KEYSYMS = (0xFFE3, 0xFFE9, 0x6D)
CHORD_TRIGGER = 'CTRL+ALT+m'
MUTTER_BUS = 'org.gnome.Mutter.RemoteDesktop'
MUTTER_PATH = '/org/gnome/Mutter/RemoteDesktop'
MUTTER_SESSION_IFACE = 'org.gnome.Mutter.RemoteDesktop.Session'


def ms(seconds):
    return round(seconds * 1000, 1)


def choose_driver(name, environ=None):
    environ = os.environ if environ is None else environ
    if name != 'auto':
        return name
    desktop = environ.get('XDG_CURRENT_DESKTOP', '').upper()
    if 'GNOME' in desktop:
        return 'mutter'
    if 'KDE' in desktop:
        return 'portal'
    return 'none'


def guarded(stage, fn, *args, **kwargs):
    """Run one stage; a failure becomes {'ok': False, 'error': ...} instead of ending the probe."""
    try:
        result = fn(*args, **kwargs)
    except portal_mod.PortalError as exc:
        return {'ok': False, 'error': f'{type(exc).__name__}: {exc}'}
    result = dict(result or {})
    result.setdefault('ok', True)
    return result


def interface_versions(portal):
    versions = {name: portal.interface_version(iface) for name, iface in INTERFACES.items()}
    try:
        registry = int(portal.get_property(portal_mod.REGISTRY_IFACE, 'version', path=portal_mod.REGISTRY_PATH))
    except portal_mod.PortalError:
        registry = 0
    versions['Registry'] = registry
    return versions


def host_portal_names(portal):
    """Bus names mentioning the host portal, owned or activatable. Shows which name serves the Registry."""
    found = {}
    for method in ('ListNames', 'ListActivatableNames'):
        body = portal.call('org.freedesktop.DBus', method, '', (), path='/org/freedesktop/DBus',
                           bus_name='org.freedesktop.DBus')
        found[method] = sorted(name for name in body[0] if 'portal' in name and not name.startswith(':'))
    return found


def introspect_interfaces(portal, path):
    """Interface names the portal service exposes at an object path."""
    import re
    body = portal.call('org.freedesktop.DBus.Introspectable', 'Introspect', '', (), path=path)
    return sorted(set(re.findall(r'<interface name="([^"]+)"', body[0])))


class MutterDriver:
    """Keyboard input through the mutter RemoteDesktop D-Bus API, no portal and no consent dialog."""
    name = 'mutter'

    def __init__(self, portal):
        self.portal = portal
        self.session = None

    def open(self):
        body = self.portal.call(MUTTER_BUS, 'CreateSession', '', (), path=MUTTER_PATH, bus_name=MUTTER_BUS)
        self.session = body[0]
        self.portal.call(MUTTER_SESSION_IFACE, 'Start', '', (), path=self.session, bus_name=MUTTER_BUS)

    def key(self, keysym, down):
        self.portal.call(MUTTER_SESSION_IFACE, 'NotifyKeyboardKeysym', 'ub', (keysym, down),
                         path=self.session, bus_name=MUTTER_BUS)

    def close(self):
        if self.session:
            try:
                self.portal.call(MUTTER_SESSION_IFACE, 'Stop', '', (), path=self.session, bus_name=MUTTER_BUS,
                                 timeout=2.0)
            except portal_mod.PortalError:
                pass
            self.session = None


class PortalKeyboardDriver:
    """Keyboard input through a RemoteDesktop portal session. Needs a prior grant or an authorized app."""
    name = 'portal'

    def __init__(self, portal, start_timeout=30.0):
        self.portal = portal
        self.start_timeout = start_timeout
        self.session = None

    def open(self):
        portal = self.portal
        self.session = portal.create_session(REMOTE_IFACE)
        portal.request(REMOTE_IFACE, 'SelectDevices', 'o', (self.session,), options={'types': ('u', 1)})
        results = portal.request(REMOTE_IFACE, 'Start', 'os', (self.session, ''), timeout=self.start_timeout)
        if not int(results.get('devices', 0)) & 1:
            raise portal_mod.PortalError('keyboard access was not granted')

    def key(self, keysym, down):
        self.portal.call(REMOTE_IFACE, 'NotifyKeyboardKeysym', 'oa{sv}iu', (self.session, {}, keysym, int(down)))

    def close(self):
        if self.session:
            self.portal.close_session(self.session, timeout=2.0)
            self.session = None


def make_driver(name, portal):
    return {'mutter': MutterDriver, 'portal': PortalKeyboardDriver}[name](portal)


def bind_chord(portal, session, bind_timeout):
    shortcut = (SHORTCUT_ID, {'description': ('s', 'Mouthtype probe chord'), 'preferred_trigger': ('s', CHORD_TRIGGER)})
    results = portal.request(SHORTCUTS_IFACE, 'BindShortcuts', 'oa(sa{sv})s', (session, [shortcut], ''),
                             timeout=bind_timeout)
    granted = []
    for shortcut_id, props in results.get('shortcuts', []):
        props = portal_mod.unwrap_variants(props)
        granted.append({'id': shortcut_id, 'trigger': props.get('trigger_description') or props.get('trigger')})
    return granted


def wait_for(portal, signals, shortcut_id, timeout):
    """Next signal for shortcut_id as (monotonic receive time, portal timestamp), or None on timeout."""
    deadline = time.monotonic() + timeout
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            return None
        try:
            message = portal.get_signal(signals, left)
        except portal_mod.PortalTimeout:
            return None
        _, got_id, stamp, _ = message.body
        if got_id == shortcut_id:
            return time.monotonic(), stamp


def run_round(portal, driver, session_signals, hold, wait):
    activated, deactivated = session_signals
    row = {}
    t_press = time.monotonic()
    for keysym in CHORD_KEYSYMS:
        driver.key(keysym, True)
    got = wait_for(portal, activated, SHORTCUT_ID, wait)
    row['activated_ms'] = ms(got[0] - t_press) if got else None
    row['activated_stamp'] = got[1] if got else None
    time.sleep(hold)
    t_release = time.monotonic()
    for keysym in reversed(CHORD_KEYSYMS):
        driver.key(keysym, False)
    got = wait_for(portal, deactivated, SHORTCUT_ID, wait)
    row['deactivated_ms'] = ms(got[0] - t_release) if got else None
    row['deactivated_stamp'] = got[1] if got else None
    row['held_ms'] = ms(t_release - t_press)
    return row


def probe_shortcuts(portal, driver_name, rounds, hold, bind_timeout, wait):
    session = portal.create_session(SHORTCUTS_IFACE)
    out = {'chord': CHORD_TRIGGER, 'driver': driver_name}
    out['granted'] = guarded('bind', lambda: {'shortcuts': bind_chord(portal, session, bind_timeout)})
    if not out['granted']['ok']:
        return out
    if driver_name == 'none':
        out['rounds'] = []
        return out
    driver = make_driver(driver_name, portal)
    try:
        driver.open()
        with portal.subscribe(SHORTCUTS_IFACE, 'Activated', None) as activated, \
                portal.subscribe(SHORTCUTS_IFACE, 'Deactivated', None) as deactivated:
            out['rounds'] = [run_round(portal, driver, (activated, deactivated), hold, wait) for _ in range(rounds)]
    except portal_mod.PortalError as exc:
        out['driver_error'] = f'{type(exc).__name__}: {exc}'
    finally:
        driver.close()
    latencies = [row['deactivated_ms'] for row in out.get('rounds', []) if row['deactivated_ms'] is not None]
    out['deactivated_received'] = len(latencies)
    if latencies:
        out['deactivated_latency_ms'] = {'min': min(latencies), 'max': max(latencies),
                                         'mean': round(sum(latencies) / len(latencies), 1)}
    return out


def run_probe(portal, args, environ=None):
    environ = os.environ if environ is None else environ
    driver_name = choose_driver(args.driver, environ)
    result = {
        'probe': 'portal',
        'app_id': portal.app_id,
        'desktop': environ.get('XDG_CURRENT_DESKTOP', ''),
        'driver': driver_name,
    }
    result['registry'] = guarded('register', lambda: {'registered': portal.register()})
    result['portal_bus_names'] = guarded('names', lambda: {'names': host_portal_names(portal)})
    result['introspection'] = {
        'desktop_path': guarded('introspect', lambda: {'interfaces': introspect_interfaces(portal, portal_mod.PORTAL_PATH)}),
        'registry_path': guarded('introspect', lambda: {'interfaces': introspect_interfaces(portal, portal_mod.REGISTRY_PATH)}),
    }
    result['interfaces'] = guarded('versions', lambda: {'versions': interface_versions(portal)})
    versions = result['interfaces'].get('versions', {})
    if versions.get('GlobalShortcuts', 0) >= 1:
        result['shortcuts'] = guarded('shortcuts', probe_shortcuts, portal, driver_name, args.rounds, args.hold,
                                      args.bind_timeout, args.wait)
    else:
        result['shortcuts'] = {'ok': False, 'error': 'portal has no GlobalShortcuts interface'}
    return result


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--app-id', default=portal_mod.APP_ID)
    parser.add_argument('--driver', choices=('auto', 'mutter', 'portal', 'none'), default='auto')
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--hold', type=float, default=0.5, help='seconds to hold the chord')
    parser.add_argument('--bind-timeout', type=float, default=20.0, help='seconds to wait for the bind dialog')
    parser.add_argument('--wait', type=float, default=3.0, help='seconds to wait for each signal')
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        with portal_mod.Portal(app_id=args.app_id) as portal:
            result = run_probe(portal, args)
    except portal_mod.PortalUnavailable as exc:
        print(json.dumps({'probe': 'portal', 'ok': False, 'error': str(exc)}, indent=2))
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
