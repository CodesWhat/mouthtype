import threading
import time
import types
import unittest

import backends
import portal
import shortcuts_portal
from shortcuts_portal import PortalShortcuts, ShortcutsUnavailable
import test_portal
from test_portal import HAVE_JEEPNEY, DBUS_DAEMON

PortalBusTests = test_portal.PortalBusTests

SHORTCUTS = 'org.freedesktop.portal.GlobalShortcuts'


class FakeSession:
    maximum_seconds = 60

    def __init__(self):
        self.state = 'idle'
        self.commands = []
        self.shortcuts_status = None
        self.changed = threading.Condition()

    def command(self, action, **kwargs):
        with self.changed:
            self.commands.append(action)
            if action == 'start' and self.state == 'idle':
                self.state = 'recording'
            elif action == 'toggle':
                self.state = 'idle' if self.state == 'recording' else 'recording'
            elif action in ('stop', 'cancel'):
                self.state = 'idle'
            self.changed.notify_all()
            return {'state': self.state}

    def wait_for(self, count, timeout=3.0):
        with self.changed:
            return self.changed.wait_for(lambda: len(self.commands) >= count, timeout)


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class ShortcutsBackendTests(unittest.TestCase):
    def test_portal_shortcuts_are_registered(self):
        self.assertIsNotNone(backends.make_shortcuts('portal', FakeSession()))
        self.assertIsNone(backends.make_shortcuts('hyprland', FakeSession()))

    def test_attach_skips_desktops_without_portal_shortcuts(self):
        session = FakeSession()
        self.assertIsNone(shortcuts_portal.attach(session, {'HYPRLAND_INSTANCE_SIGNATURE': 'x'}))
        self.assertIsNone(shortcuts_portal.attach(session, {'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'wayland'}, 'none'))
        self.assertIsNone(session.shortcuts_status)

    def test_attach_survives_a_missing_portal(self):
        class Dead:
            def __init__(self, **kwargs):
                pass

            def connect(self):
                raise portal.PortalUnavailable('no bus')

            def close(self):
                pass
        session = FakeSession()
        shortcuts = PortalShortcuts(session, portal_factory=Dead)
        with self.assertRaises(ShortcutsUnavailable):
            shortcuts.start()
        self.assertEqual(session.shortcuts_status['state'], 'failed')


@unittest.skipUnless(HAVE_JEEPNEY and DBUS_DAEMON, 'needs python3-jeepney and dbus-daemon')
class PortalShortcutsTests(unittest.TestCase):
    setUpClass = classmethod(PortalBusTests.setUpClass.__func__)
    tearDownClass = classmethod(PortalBusTests.tearDownClass.__func__)
    assert_no_leaked_threads = PortalBusTests.assert_no_leaked_threads

    def setUp(self):
        from testing.fake_portal import FakePortal
        self.threads_before = {t.ident for t in threading.enumerate()}
        self.fake = FakePortal(self.address).start()
        self.addCleanup(self.fake.stop)
        self.addCleanup(self.assert_no_leaked_threads)
        self.session = FakeSession()
        self.clock = Clock()
        self.shortcuts = PortalShortcuts(self.session, bus=self.address, clock=self.clock,
                                         portal_factory=lambda **kw: portal.Portal(bus=kw['bus'], timeout=2.0))
        self.addCleanup(self.shortcuts.stop)

    def started(self):
        self.shortcuts.start()
        return next(iter(self.fake.sessions))

    def settle(self):
        time.sleep(0.3)

    def test_binds_four_actions_after_registering(self):
        self.started()
        self.assertEqual(self.fake.registered_apps, ['app.mouthtype.Mouthtype'])
        bind = next(c for c in self.fake.calls if c[1] == 'BindShortcuts')
        self.assertEqual([sid for sid, _ in bind[3][1]],
                         ['dictate-hold', 'dictate-toggle', 'cancel', 'transform-open'])

    def test_status_reports_granted_triggers_not_preferences(self):
        self.fake.grants = {'dictate-hold': 'Ctrl+Alt+H', 'cancel': 'Esc'}
        self.started()
        status = self.shortcuts.status()
        self.assertEqual(status['triggers'], {'dictate-hold': 'Ctrl+Alt+H', 'cancel': 'Esc'})
        self.assertEqual(self.session.shortcuts_status['triggers'], status['triggers'])
        self.assertEqual(status['version'], 2)

    def test_hold_starts_on_activated_and_stops_on_deactivated(self):
        handle = self.started()
        self.fake.emit_activated(handle, 'dictate-hold')
        self.assertTrue(self.session.wait_for(1))
        self.assertEqual(self.session.state, 'recording')
        self.fake.emit_deactivated(handle, 'dictate-hold')
        self.assertTrue(self.session.wait_for(2))
        self.assertEqual(self.session.commands, ['start', 'stop'])

    def test_repeated_activated_while_held_is_ignored(self):
        handle = self.started()
        for _ in range(3):
            self.fake.emit_activated(handle, 'dictate-hold')
        self.assertTrue(self.session.wait_for(1))
        self.settle()
        self.assertEqual(self.session.commands, ['start'])

    def test_toggle_and_cancel_map_to_commands(self):
        handle = self.started()
        self.fake.emit_activated(handle, 'dictate-toggle')
        self.assertTrue(self.session.wait_for(1))
        self.fake.emit_deactivated(handle, 'dictate-toggle')
        self.fake.emit_activated(handle, 'dictate-toggle')
        self.assertTrue(self.session.wait_for(2))
        self.fake.emit_activated(handle, 'cancel')
        self.assertTrue(self.session.wait_for(3))
        self.assertEqual(self.session.commands, ['toggle', 'toggle', 'cancel'])

    def test_deactivated_without_a_hold_does_not_stop_another_take(self):
        handle = self.started()
        self.session.state = 'recording'
        self.fake.emit_activated(handle, 'dictate-hold')
        self.assertTrue(self.session.wait_for(1))
        self.fake.emit_deactivated(handle, 'dictate-hold')
        self.settle()
        self.assertEqual(self.session.commands, ['start'])

    def test_missing_deactivated_stops_at_the_maximum_duration(self):
        handle = self.started()
        self.fake.emit_activated(handle, 'dictate-hold')
        self.assertTrue(self.session.wait_for(1))
        self.clock.now += 61
        self.assertTrue(self.session.wait_for(2))
        self.assertEqual(self.session.commands, ['start', 'stop'])

    def test_session_loss_ends_a_held_take(self):
        handle = self.started()
        self.fake.emit_activated(handle, 'dictate-hold')
        self.assertTrue(self.session.wait_for(1))
        self.fake.emit_session_closed(handle)
        self.assertTrue(self.session.wait_for(2))
        self.assertEqual(self.session.commands, ['start', 'stop'])
        self.assertEqual(self.shortcuts.status()['state'], 'lost')

    def test_signals_for_another_session_are_ignored(self):
        self.started()
        self.fake.emit_activated('/org/freedesktop/portal/desktop/session/other', 'dictate-toggle')
        self.settle()
        self.assertEqual(self.session.commands, [])

    def test_portal_restart_stops_the_take_and_rebinds(self):
        handle = self.started()
        self.fake.emit_activated(handle, 'dictate-hold')
        self.assertTrue(self.session.wait_for(1))
        self.fake.restart()
        self.assertTrue(self.session.wait_for(2, 5))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and self.shortcuts.status()['state'] != 'bound':
            time.sleep(0.05)
        self.assertEqual(self.shortcuts.status()['state'], 'bound')
        fresh = next(iter(self.fake.sessions))
        self.fake.emit_activated(fresh, 'dictate-toggle')
        self.assertTrue(self.session.wait_for(3))

    def test_refused_bind_is_unavailable(self):
        self.fake.response_codes['BindShortcuts'] = 1
        with self.assertRaises(ShortcutsUnavailable):
            self.shortcuts.start()
        self.assertEqual(self.session.shortcuts_status['state'], 'failed')
        self.assertEqual(self.fake.sessions, set())

    def test_portal_without_global_shortcuts_is_unavailable(self):
        self.fake.versions.clear()
        with self.assertRaises(ShortcutsUnavailable):
            self.shortcuts.start()

    def test_transform_open_calls_the_handler(self):
        opened = threading.Event()
        self.shortcuts.on_transform_open = opened.set
        handle = self.started()
        self.fake.emit_activated(handle, 'transform-open')
        self.assertTrue(opened.wait(3))

    def test_configure_calls_the_portal_on_a_v2_session(self):
        handle = self.started()
        result = shortcuts_portal.configure(self.shortcuts, {'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'wayland'},
                                            opener=self.fail)
        self.assertEqual(result['method'], 'portal')
        self.assertEqual(result['triggers']['dictate-hold'], 'CTRL+ALT+M')
        call = next(c for c in self.fake.calls if c[1] == 'ConfigureShortcuts')
        self.assertEqual(call[3][0], handle)

    def test_v1_portal_on_gnome_opens_keyboard_settings(self):
        self.fake.versions[SHORTCUTS] = 1
        self.started()
        opened = []
        result = shortcuts_portal.configure(self.shortcuts, GNOME_ENV, opener=Opener(opened))
        self.assertEqual(result['method'], 'gnome-control-center')
        self.assertEqual(opened, [['gnome-control-center', 'keyboard']])
        self.assertFalse(any(c[1] == 'ConfigureShortcuts' for c in self.fake.calls))

    def test_v1_portal_on_gnome_without_settings_reports_why(self):
        self.fake.versions[SHORTCUTS] = 1
        self.started()
        result = shortcuts_portal.configure(self.shortcuts, GNOME_ENV, opener=Opener([], FileNotFoundError('nope')))
        self.assertEqual(result['error'], 'configure_unavailable')
        self.assertIn('gnome-control-center did not start', result['reason'])
        self.assertEqual(result['triggers']['dictate-hold'], 'CTRL+ALT+M')

    def test_v1_portal_on_kde_reports_unavailable(self):
        self.fake.versions[SHORTCUTS] = 1
        self.started()
        result = shortcuts_portal.configure(self.shortcuts, {'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'wayland'},
                                            opener=self.fail)
        self.assertEqual(result['error'], 'configure_unavailable')
        self.assertIn('version 2', result['reason'])

    def test_configure_before_binding_is_refused(self):
        with self.assertRaises(ShortcutsUnavailable):
            self.shortcuts.configure()


GNOME_ENV = {'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME', 'XDG_SESSION_TYPE': 'wayland'}


class Opener:
    def __init__(self, record, error=None):
        self.record, self.error = record, error

    def __call__(self, argv, **kwargs):
        if self.error:
            raise self.error
        self.record.append(argv)
        return types.SimpleNamespace(wait=lambda: 0)


class NoPortalConfigureTests(unittest.TestCase):
    def test_gnome_without_a_portal_still_opens_settings(self):
        opened = []
        result = shortcuts_portal.configure(None, GNOME_ENV, opener=Opener(opened))
        self.assertEqual(result['method'], 'gnome-control-center')
        self.assertEqual(result['backend'], 'none')
        self.assertEqual(opened, [['gnome-control-center', 'keyboard']])

    def test_missing_settings_app_is_reported(self):
        result = shortcuts_portal.configure(None, GNOME_ENV, opener=Opener([], FileNotFoundError('nope')))
        self.assertEqual(result['error'], 'configure_unavailable')
        self.assertIn('did not start', result['reason'])

    def test_hyprland_has_nothing_to_open(self):
        result = shortcuts_portal.configure(None, {'HYPRLAND_INSTANCE_SIGNATURE': 'x'}, opener=lambda *a, **k: self.fail())
        self.assertEqual(result['error'], 'configure_unavailable')

    def test_status_without_a_backend(self):
        status = shortcuts_portal.status_of(None)
        self.assertEqual((status['backend'], status['state'], status['triggers']), ('none', 'unavailable', {}))


if __name__ == '__main__':
    unittest.main()
