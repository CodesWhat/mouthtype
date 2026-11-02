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

    # clipboard ----------------------------------------------------------

    def clipboard(self, **kwargs):
        self.remote.start(interactive=True)
        clip = delivery_portal.PortalClipboard(self.remote, owner_timeout=2.0, **kwargs)
        self.addCleanup(clip.close)
        clip.start()
        return clip

    def wait_for(self, condition, what):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(0.02)
        self.fail(f'timed out waiting for {what}')

    def paste(self, mime):
        serial = self.fake.request_paste(self.remote.session, mime)
        self.wait_for(lambda: serial in self.fake.transfers, f'transfer {serial}')
        return self.fake.transfers[serial]

    def external_copy(self, clip, offers):
        self.fake.external_copy(self.remote.session, offers)
        self.wait_for(lambda: clip._owner_mimes == list(offers), 'owner change')

    def test_clipboard_needs_an_active_session(self):
        clip = delivery_portal.PortalClipboard(self.remote)
        with self.assertRaises(portal.PortalError):
            clip.start()

    def test_copy_offers_every_text_type_and_serves_them(self):
        clip = self.clipboard()
        clip.copy('héllo')
        self.assertEqual(self.fake.owned, list(delivery_portal.TEXT_MIMES))
        self.assertEqual(self.paste('text/plain;charset=utf-8'), (True, 'héllo'.encode()))
        self.assertEqual(self.paste('text/plain'), (True, 'héllo'.encode()))

    def test_unoffered_type_is_refused(self):
        clip = self.clipboard()
        clip.copy('x')
        self.assertEqual(self.paste('image/png'), (False, b''))

    def test_concealed_copy_adds_the_password_manager_hint(self):
        clip = self.clipboard()
        clip.copy('secret words', concealed=True)
        self.assertIn('x-kde-passwordManagerHint', self.fake.owned)
        self.assertEqual(self.paste('x-kde-passwordManagerHint'), (True, b'secret'))
        clip.copy('plain')
        self.assertNotIn('x-kde-passwordManagerHint', self.fake.owned)

    def test_restore_puts_the_previous_selection_back(self):
        clip = self.clipboard()
        self.external_copy(clip, {'text/plain;charset=utf-8': b'before', 'text/html': b'<b>before</b>'})
        copy = clip.copy('dictated')
        self.assertEqual(copy.previous, {'text/plain;charset=utf-8': b'before', 'text/html': b'<b>before</b>'})
        self.fake.clipboard = copy.previous
        self.assertTrue(clip.restore(copy))
        self.assertEqual(self.fake.owned, ['text/plain;charset=utf-8', 'text/html'])
        self.assertEqual(self.paste('text/html'), (True, b'<b>before</b>'))

    def test_restore_is_cancelled_when_someone_else_copied(self):
        clip = self.clipboard()
        self.external_copy(clip, {'text/plain': b'before'})
        copy = clip.copy('dictated')
        self.fake.external_copy(self.remote.session, {'text/plain': b'user copy'})
        self.wait_for(lambda: not clip.owns(copy.generation), 'ownership loss')
        offers_before = len([c for c in self.fake.calls if c[1] == 'SetSelection'])
        self.assertFalse(clip.restore(copy))
        self.assertEqual(len([c for c in self.fake.calls if c[1] == 'SetSelection']), offers_before)

    def test_restore_skipped_when_nothing_was_readable(self):
        clip = self.clipboard()
        copy = clip.copy('dictated')
        self.assertEqual(copy.previous, {})
        self.assertFalse(clip.restore(copy))

    def test_oversized_previous_type_is_dropped_not_truncated(self):
        clip = self.clipboard(read_cap=8)
        self.external_copy(clip, {'text/plain': b'short', 'text/html': b'x' * 100})
        self.assertEqual(clip.read_current(), {'text/plain': b'short'})

    def test_unreadable_previous_type_is_skipped(self):
        clip = self.clipboard()
        self.fake.read_errors.add('text/html')
        self.external_copy(clip, {'text/plain': b'a', 'text/html': b'b'})
        self.assertEqual(clip.read_current(), {'text/plain': b'a'})

    def test_second_copy_supersedes_the_first_restore(self):
        clip = self.clipboard()
        self.external_copy(clip, {'text/plain': b'before'})
        first = clip.copy('one')
        second = clip.copy('two')
        self.assertFalse(clip.owns(first.generation))
        self.assertTrue(clip.owns(second.generation))
        self.assertFalse(clip.restore(first))

    def test_close_stops_the_serving_thread(self):
        clip = self.clipboard()
        clip.copy('x')
        clip.close()
        clip.close()
        self.assertFalse([t for t in threading.enumerate() if t.name == 'mouthtype-portal-clipboard'])

    # delivery -----------------------------------------------------------

    def delivery(self, **config):
        clip = self.clipboard()
        base = {'mode': 'paste', 'allow_unknown_secure_field': True, 'any_window': True, 'restore_delay_seconds': 0}
        delivery = delivery_portal.PortalDelivery({**base, **config}, self.remote, clip, targets=self.targets)
        self.addCleanup(lambda: delivery.restore_thread and delivery.restore_thread.join(2))
        return delivery

    targets = None

    class Targets:
        def __init__(self, target, terminal=False):
            self.target, self.terminal = target, terminal

        def snapshot(self):
            return self.target

        def is_terminal(self, target):
            return self.terminal

    def test_paste_sends_ctrl_v_with_the_text_on_the_clipboard(self):
        delivery = self.delivery()
        self.assertEqual(delivery.paste('héllo', {'class': 'unknown'}), 'unknown')
        self.assertEqual(self.fake.keysyms, [(0xFFE3, 1), (0x76, 1), (0x76, 0), (0xFFE3, 0)])
        self.assertEqual(self.paste('text/plain;charset=utf-8'), (True, 'héllo'.encode()))

    def test_terminal_paste_adds_shift_and_drops_the_trailing_newline(self):
        self.targets = self.Targets({'class': 'unknown'}, terminal=True)
        delivery = self.delivery()
        self.assertEqual(delivery.paste('ls\n', {'class': 'unknown'}), 'unknown')
        self.assertEqual(self.fake.keysyms, [(0xFFE3, 1), (0xFFE1, 1), (0x76, 1), (0x76, 0), (0xFFE1, 0), (0xFFE3, 0)])
        self.assertEqual(self.paste('text/plain'), (True, b'ls'))
        self.assertEqual(delivery.paste('a\nb', {'class': 'unknown'}), 'unsupported_text')

    def test_paste_restores_the_previous_selection(self):
        delivery = self.delivery()
        self.external_copy(delivery.clipboard, {'text/plain': b'before'})
        delivery.paste('dictated', {'class': 'unknown'})
        self.fake.clipboard = {'text/plain': b'before'}
        delivery.restore_thread.join(2)
        self.assertEqual(self.fake.owned, ['text/plain'])

    def test_sensitive_previous_selection_is_not_restored(self):
        delivery = self.delivery()
        self.external_copy(delivery.clipboard, {'text/plain': b'pw', 'x-kde-passwordManagerHint': b'secret'})
        delivery.paste('dictated', {'class': 'unknown'})
        self.assertIsNone(delivery.restore_thread)
        self.assertEqual(self.fake.owned, list(delivery_portal.TEXT_MIMES))

    def test_target_change_blocks_the_chord(self):
        self.targets = self.Targets({'class': 'other'})
        delivery = self.delivery()
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}), 'target_changed')
        self.assertEqual(self.fake.keysyms, [])
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}, verified=True), 'target_changed')

    def test_secure_target_is_refused_everywhere(self):
        secure = {'class': 'gtk', 'secure': True}
        self.targets = self.Targets(secure)
        for mode in ('type', 'paste'):
            delivery = self.delivery(mode=mode)
            self.assertFalse(delivery.allowed(secure))
            self.assertEqual(delivery.submit('hi', secure), 'recover_only')
        self.assertEqual(delivery.paste('hi', secure), 'recover_only')
        self.assertEqual(delivery.type_text('hi', secure), 'recover_only')
        self.assertEqual(self.fake.keysyms, [])

    def test_cancel_and_control_characters_send_nothing(self):
        delivery = self.delivery()
        event = threading.Event()
        event.set()
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}, event), 'not_attempted')
        self.assertEqual(delivery.paste('a\x1bb', {'class': 'unknown'}), 'unsupported_text')
        self.assertEqual(self.fake.keysyms, [])

    def test_inactive_session_is_recover_only(self):
        delivery = self.delivery()
        self.remote.revoked()
        self.assertEqual(delivery.submit('x', {'class': 'unknown'}), 'recover_only')
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}), 'recover_only')

    def test_type_mode_sends_one_keysym_per_character(self):
        delivery = self.delivery(mode='type')
        self.assertEqual(delivery.submit('aé→', {'class': 'unknown'}), 'unknown')
        self.assertEqual(self.fake.keysyms, [(0x61, 1), (0x61, 0), (0xE9, 1), (0xE9, 0),
                                             (0x01002192, 1), (0x01002192, 0)])
        self.assertNotIn('SetSelection', [m for _, m, _, _ in self.fake.calls])

    def test_type_mode_falls_back_to_paste_for_multiline_and_long_text(self):
        delivery = self.delivery(mode='type', type_max_chars=5)
        self.assertEqual(delivery.submit('a\nb', {'class': 'unknown'}), 'unknown')
        self.assertEqual(delivery.submit('abcdefghij', {'class': 'unknown'}), 'unknown')
        self.assertEqual(self.paste('text/plain'), (True, b'abcdefghij'))
        self.assertEqual({k for k, _ in self.fake.keysyms}, {0xFFE3, 0x76})

    def test_type_mode_falls_back_to_paste_when_the_first_keysym_fails(self):
        delivery = self.delivery(mode='type')
        self.fake.keysym_error = True
        self.assertEqual(delivery.type_text('abc', {'class': 'unknown'}), 'fallback')
        self.assertEqual(delivery.submit('abc', {'class': 'unknown'}), 'unknown')
        self.assertEqual(self.paste('text/plain'), (True, b'abc'))

    def test_allowed_follows_the_hyprland_rules(self):
        delivery = self.delivery(any_window=False, allowed_classes=['firefox'])
        self.assertTrue(delivery.allowed({'class': 'firefox'}))
        self.assertFalse(delivery.allowed({'class': 'unknown'}))
        self.assertEqual(delivery.submit('x', {'class': 'unknown'}), 'recover_only')
        delivery.config['allow_unknown_secure_field'] = False
        self.assertFalse(delivery.allowed({'class': 'firefox'}))


    # lazy rebind --------------------------------------------------------

    def recover_only_delivery(self):
        self.assertEqual(self.remote.start(), 'needs_grant')
        clip = delivery_portal.PortalClipboard(self.remote, owner_timeout=2.0)
        self.addCleanup(clip.close)
        base = {'mode': 'paste', 'allow_unknown_secure_field': True, 'any_window': True, 'restore_delay_seconds': 0}
        delivery = delivery_portal.PortalDelivery(base, self.remote, clip, targets=self.targets)
        self.addCleanup(lambda: delivery.restore_thread and delivery.restore_thread.join(2))
        return delivery

    def test_no_grant_makes_no_portal_call_on_a_take(self):
        delivery = self.recover_only_delivery()
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}), 'recover_only')
        self.assertEqual(self.members(), [])

    def test_a_grant_made_after_start_is_picked_up_on_the_next_take(self):
        delivery = self.recover_only_delivery()
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}), 'recover_only')
        self.store.save('grant-1')
        self.fake.valid_grants.add('grant-1')
        self.fake.deny_new_grants = True
        self.assertEqual(delivery.paste('later', {'class': 'unknown'}), 'unknown')
        self.assertEqual(self.remote.status, 'active')
        self.assertEqual(self.paste('text/plain;charset=utf-8'), (True, b'later'))

    def test_a_failed_rebind_backs_off_instead_of_stalling_every_take(self):
        delivery = self.recover_only_delivery()
        self.store.save('stale')
        self.fake.deny_new_grants = True
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}), 'recover_only')
        calls = len(self.fake.calls)
        self.assertEqual(delivery.paste('x', {'class': 'unknown'}), 'recover_only')
        self.assertEqual(len(self.fake.calls), calls)
        delivery._rebind_after = 0.0
        self.store.save('grant-1')
        self.fake.valid_grants.add('grant-1')
        self.assertEqual(delivery.paste('ok', {'class': 'unknown'}), 'unknown')

    def test_portal_restart_rebinds_session_and_clipboard(self):
        delivery = self.delivery()
        self.assertEqual(delivery.paste('one', {'class': 'unknown'}), 'unknown')
        self.fake.restart()
        self.client.register()
        self.fake.deny_new_grants = True
        self.fake.valid_grants.add('grant-1')
        delivery.portal_restarted()
        self.assertEqual(self.remote.status, 'active')
        self.fake.keysyms.clear()
        self.assertEqual(delivery.paste('two', {'class': 'unknown'}), 'unknown')
        self.assertEqual(self.paste('text/plain;charset=utf-8'), (True, b'two'))
        self.assertEqual(len(self.fake.keysyms), 4)

    def test_watcher_callback_rebinds_after_a_real_restart(self):
        delivery = self.delivery()
        done = threading.Event()
        self.client.watch_restarts(lambda: (delivery.portal_restarted(), done.set()))
        self.fake.deny_new_grants = True
        self.fake.valid_grants.add('grant-1')
        self.fake.restart()
        self.assertTrue(done.wait(10))
        self.assertEqual(self.remote.status, 'active')
        self.assertEqual(delivery.paste('after', {'class': 'unknown'}), 'unknown')


class KeysymTests(unittest.TestCase):
    def test_mapping(self):
        keysym = delivery_portal.keysym_for
        self.assertEqual(keysym('a'), 0x61)
        self.assertEqual(keysym('\xe9'), 0xE9)
        self.assertEqual(keysym('\u20ac'), 0x010020AC)
        self.assertEqual(keysym('\U0001f600'), 0x0101F600)
        self.assertEqual(keysym('\n'), 0xFF0D)
        self.assertEqual(keysym('\t'), 0xFF09)
        self.assertIsNone(keysym('\x1b'))
        self.assertIsNone(keysym('\x85'))


if __name__ == '__main__':
    unittest.main()
