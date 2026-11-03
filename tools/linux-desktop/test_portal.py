import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
import unittest

import portal

try:
    import jeepney  # noqa: F401
    HAVE_JEEPNEY = True
except ImportError:
    HAVE_JEEPNEY = False

DBUS_DAEMON = shutil.which('dbus-daemon')
BUS_CONFIG = '''<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:dir={dir}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
'''
SHORTCUTS = 'org.freedesktop.portal.GlobalShortcuts'


class PortalHelperTests(unittest.TestCase):
    def test_request_path_matches_the_portal_convention(self):
        self.assertEqual(portal.sender_token(':1.42'), '1_42')
        self.assertEqual(
            portal.request_path(':1.42', 'tok_1'),
            '/org/freedesktop/portal/desktop/request/1_42/tok_1',
        )

    def test_unwrap_variants_strips_signatures(self):
        self.assertEqual(portal.unwrap_variants({'a': ('s', 'x'), 'b': ('u', 3)}), {'a': 'x', 'b': 3})

    def test_response_error_reports_cancel(self):
        self.assertTrue(portal.PortalResponseError(1).cancelled)
        self.assertFalse(portal.PortalResponseError(2).cancelled)


@unittest.skipUnless(HAVE_JEEPNEY and DBUS_DAEMON, 'needs python3-jeepney and dbus-daemon')
class PortalBusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        config = Path(cls.temp.name) / 'bus.conf'
        config.write_text(BUS_CONFIG.format(dir=cls.temp.name))
        cls.daemon = subprocess.Popen(
            [DBUS_DAEMON, f'--config-file={config}', '--nofork', '--print-address=1'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        cls.address = cls.daemon.stdout.readline().strip()
        if not cls.address:
            cls.daemon.kill()
            cls.daemon.wait(timeout=5)
            cls.daemon.stdout.close()
            cls.temp.cleanup()
            raise unittest.SkipTest('dbus-daemon did not print an address')

    @classmethod
    def tearDownClass(cls):
        cls.daemon.terminate()
        try:
            cls.daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            cls.daemon.kill()
            cls.daemon.wait(timeout=5)
        cls.daemon.stdout.close()
        cls.temp.cleanup()

    def setUp(self):
        from testing.fake_portal import FakePortal
        self.threads_before = {t.ident for t in threading.enumerate()}
        self.fake = FakePortal(self.address).start()
        self.addCleanup(self.fake.stop)
        self.client = portal.Portal(bus=self.address, timeout=2.0)
        self.addCleanup(self.assert_no_leaked_threads)
        self.addCleanup(self.client.close)

    def assert_no_leaked_threads(self):
        self.fake.stop()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            extra = [t for t in threading.enumerate() if t.ident not in self.threads_before]
            if not extra:
                return
            time.sleep(0.02)
        self.fail(f'leaked threads: {extra}')

    def test_register_sends_the_app_id(self):
        self.client.connect()
        self.assertTrue(self.client.register())
        self.assertEqual(self.fake.registered_apps, ['app.mouthtype.Mouthtype'])
        self.assertTrue(self.client.registered)

    def test_register_tolerates_a_portal_without_the_registry(self):
        self.fake.registry_error = 'org.freedesktop.DBus.Error.UnknownMethod'
        self.client.connect()
        self.assertFalse(self.client.register())
        self.assertFalse(self.client.registered)

    def test_register_surfaces_other_errors(self):
        self.fake.registry_error = 'org.freedesktop.DBus.Error.AccessDenied'
        self.client.connect()
        with self.assertRaises(portal.PortalError):
            self.client.register()

    def test_interface_version(self):
        self.client.connect()
        self.assertEqual(self.client.interface_version(SHORTCUTS), 2)
        self.assertEqual(self.client.interface_version('org.freedesktop.portal.RemoteDesktop'), 0)

    def test_session_and_bind_round_trip(self):
        self.client.connect().register()
        session = self.client.create_session(SHORTCUTS)
        self.assertIn(session, self.fake.sessions)
        results = self.client.request(
            SHORTCUTS, 'BindShortcuts', 'oa(sa{sv})s',
            (session, [('dictate-toggle', {'description': ('s', 'Dictate'), 'preferred_trigger': ('s', 'CTRL+ALT+M')})], ''),
        )
        self.assertEqual(results['shortcuts'][0][0], 'dictate-toggle')
        self.client.close_session(session)
        self.assertNotIn(session, self.fake.sessions)

    def test_signal_subscription_delivers_activated(self):
        self.client.connect().register()
        session = self.client.create_session(SHORTCUTS)
        with self.client.subscribe(SHORTCUTS, 'Activated') as signals:
            self.fake.emit_activated(session, 'dictate-hold', timestamp=1234)
            message = self.client.get_signal(signals, 2.0)
        self.assertEqual(message.body[:3], (session, 'dictate-hold', 1234))

    def test_missing_signal_times_out(self):
        self.client.connect()
        with self.client.subscribe(SHORTCUTS, 'Activated') as signals:
            started = time.monotonic()
            with self.assertRaises(portal.PortalTimeout):
                self.client.get_signal(signals, 0.2)
        self.assertLess(time.monotonic() - started, 1.5)

    def test_silent_request_times_out_and_closes_the_request(self):
        self.fake.silent.add('CreateSession')
        self.client.connect()
        started = time.monotonic()
        with self.assertRaises(portal.PortalTimeout):
            self.client.create_session(SHORTCUTS, timeout=0.3)
        self.assertLess(time.monotonic() - started, 2.0)
        self.assertTrue(any(c[0] == 'org.freedesktop.portal.Request' and c[1] == 'Close' for c in self.fake.calls))

    def test_denied_response_raises_with_the_code(self):
        self.fake.response_codes['CreateSession'] = 1
        self.client.connect()
        with self.assertRaises(portal.PortalResponseError) as caught:
            self.client.create_session(SHORTCUTS)
        self.assertTrue(caught.exception.cancelled)

    def test_unknown_method_is_a_portal_error(self):
        self.client.connect()
        with self.assertRaises(portal.PortalError):
            self.client.call(SHORTCUTS, 'NoSuchMethod')

    def test_unreachable_bus_is_unavailable(self):
        dead = portal.Portal(bus='unix:path=/nonexistent/mouthtype-bus', timeout=1.0)
        with self.assertRaises(portal.PortalUnavailable):
            dead.connect()

    def test_calls_after_close_fail_cleanly(self):
        self.client.connect().register()
        self.client.close()
        with self.assertRaises(portal.PortalError):
            self.client.call(SHORTCUTS, 'CreateSession')

    def test_close_closes_tracked_sessions(self):
        self.client.connect().register()
        session = self.client.create_session(SHORTCUTS)
        self.client.close()
        self.assertNotIn(session, self.fake.sessions)

    def test_restart_reregisters_and_calls_back(self):
        fired = threading.Event()
        self.client.connect().register()
        session = self.client.create_session(SHORTCUTS)
        self.client.watch_restarts(fired.set)
        self.fake.restart()
        self.assertTrue(fired.wait(5), 'restart callback never ran')
        self.assertEqual(self.fake.registered_apps, ['app.mouthtype.Mouthtype'] * 2)
        self.assertTrue(self.client.registered)
        self.client.close()
        self.assertNotIn(session, self.fake.sessions)

    def test_second_restart_watcher_is_rejected(self):
        self.client.connect()
        self.client.watch_restarts(lambda: None)
        with self.assertRaises(portal.PortalError):
            self.client.watch_restarts(lambda: None)


if __name__ == '__main__':
    unittest.main()
