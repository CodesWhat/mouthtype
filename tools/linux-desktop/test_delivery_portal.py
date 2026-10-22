import os
import stat
import subprocess
import tempfile
import threading
import time
from pathlib import Path
import unittest

import delivery_portal
import portal
from test_portal import BUS_CONFIG, DBUS_DAEMON, HAVE_JEEPNEY

REMOTE = 'org.freedesktop.portal.RemoteDesktop'


class GrantStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.store = delivery_portal.GrantStore(Path(self.temp.name) / 'state' / 'portal.json')

    def test_round_trip_is_private(self):
        self.assertIsNone(self.store.load())
        self.store.save('grant-1')
        self.assertEqual(self.store.load(), 'grant-1')
        self.assertEqual(stat.S_IMODE(os.stat(self.store.path).st_mode), 0o600)
        self.assertEqual([p.name for p in self.store.path.parent.iterdir()], ['portal.json'])

    def test_garbage_and_clear(self):
        self.store.path.parent.mkdir(parents=True)
        self.store.path.write_text('not json')
        self.assertIsNone(self.store.load())
        self.store.save('g')
        self.store.clear()
        self.store.clear()
        self.assertIsNone(self.store.load())

    def test_path_follows_xdg_state_home(self):
        self.assertEqual(delivery_portal.grant_store_path({'XDG_STATE_HOME': '/s'}), Path('/s/mouthtype/portal.json'))


@unittest.skipUnless(HAVE_JEEPNEY and DBUS_DAEMON, 'needs python3-jeepney and dbus-daemon')
class RemoteDesktopSessionTests(unittest.TestCase):
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
        self.fake = FakePortal(self.address, versions={REMOTE: 2}).start()
        self.addCleanup(self.fake.stop)
        self.client = portal.Portal(bus=self.address, timeout=2.0)
        self.addCleanup(self.assert_no_leaked_threads)
        self.addCleanup(self.client.close)
        self.client.connect().register()
        self.state = tempfile.TemporaryDirectory()
        self.addCleanup(self.state.cleanup)
        self.store = delivery_portal.GrantStore(Path(self.state.name) / 'portal.json')
        self.remote = delivery_portal.RemoteDesktopSession(self.client, self.store, start_timeout=2.0)
        self.addCleanup(self.remote.close)

    def assert_no_leaked_threads(self):
        self.fake.stop()
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            extra = [t for t in threading.enumerate() if t.ident not in self.threads_before]
            if not extra:
                return
            time.sleep(0.02)
        self.fail(f'leaked threads: {extra}')

    def members(self):
        return [(i.rsplit('.', 1)[-1], m) for i, m, _, _ in self.fake.calls
                if i.rsplit('.', 1)[-1] in ('RemoteDesktop', 'Clipboard')]

    def test_first_run_prompts_only_when_interactive(self):
        self.assertEqual(self.remote.start(), 'needs_grant')
        self.assertEqual(self.members(), [])
        self.assertEqual(self.remote.start(interactive=True), 'active')
        self.assertEqual(self.members(), [('RemoteDesktop', 'CreateSession'), ('RemoteDesktop', 'SelectDevices'),
                                          ('Clipboard', 'RequestClipboard'), ('RemoteDesktop', 'Start')])
        self.assertTrue(self.remote.active)

    def test_selects_keyboard_only_and_persists(self):
        self.remote.start(interactive=True)
        options = next(iter(self.fake.selected.values()))
        self.assertEqual(options['types'], 1)
        self.assertEqual(options['persist_mode'], 2)
        self.assertNotIn('restore_token', options)
        self.assertEqual(self.store.load(), 'grant-1')

    def test_restore_round_trip_starts_without_a_prompt(self):
        self.remote.start(interactive=True)
        self.remote.close()
        again = delivery_portal.RemoteDesktopSession(self.client, self.store, start_timeout=2.0)
        self.addCleanup(again.close)
        self.fake.deny_new_grants = True
        self.assertEqual(again.start(), 'active')
        options = list(self.fake.selected.values())[-1]
        self.assertEqual(options['restore_token'], 'grant-1')
        self.assertEqual(self.store.load(), 'grant-1')

    def test_revoked_grant_goes_recover_only_and_forgets_it(self):
        self.store.save('stale')
        self.fake.deny_new_grants = True
        self.assertEqual(self.remote.start(), 'needs_grant')
        self.assertIsNone(self.store.load())
        self.assertFalse(self.remote.active)
        self.assertIsNone(self.remote.session)
        self.assertEqual(self.remote.start(), 'needs_grant')

    def test_cancelled_first_grant_is_needs_grant(self):
        self.fake.deny_new_grants = True
        self.assertEqual(self.remote.start(interactive=True), 'needs_grant')
        self.assertIn('cancelled', self.remote.detail)
        self.assertIsNone(self.store.load())

    def test_start_without_keyboard_device_is_needs_grant(self):
        self.fake.devices_granted = 0
        self.assertEqual(self.remote.start(interactive=True), 'needs_grant')
        self.assertIsNone(self.store.load())

    def test_portal_without_remote_desktop_is_unavailable(self):
        self.fake.versions.pop(REMOTE)
        self.assertEqual(self.remote.start(interactive=True), 'unavailable')

    def test_desktop_closing_the_session_is_noticed(self):
        self.remote.start(interactive=True)
        session = self.remote.session
        self.fake.emit_session_closed(session)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and self.remote.check() == 'active':
            time.sleep(0.02)
        self.assertEqual(self.remote.status, 'needs_grant')
        self.assertFalse(self.remote.active)

    def test_timeout_is_unavailable_and_leaves_no_session(self):
        self.fake.silent.add('Start')
        self.remote.start_timeout = 0.3
        self.assertEqual(self.remote.start(interactive=True), 'unavailable')
        self.assertIsNone(self.remote.session)

    def test_portal_restart_reconnects_from_the_stored_grant(self):
        self.remote.start(interactive=True)
        self.fake.restart()
        self.client.register()
        self.fake.deny_new_grants = True
        self.fake.valid_grants.add('grant-1')
        self.assertEqual(self.remote.on_portal_restart(), 'active')

    def test_revoked_call_clears_the_store(self):
        self.remote.start(interactive=True)
        self.assertEqual(self.remote.revoked(), 'needs_grant')
        self.assertIsNone(self.store.load())
        self.assertIsNone(self.remote.session)


if __name__ == '__main__':
    unittest.main()
