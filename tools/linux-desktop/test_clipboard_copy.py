import argparse
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import cli_automation
import clipboard_copy
import delivery_portal
import desktop
import portal
from test_stats import hexid, make_take, stamp

GNOME = {'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'wayland'}
KDE = {'XDG_CURRENT_DESKTOP': 'KDE', 'XDG_SESSION_TYPE': 'wayland'}
HYPRLAND = {'HYPRLAND_INSTANCE_SIGNATURE': 'abc', 'XDG_CURRENT_DESKTOP': 'Hyprland'}


class StubRemote:
    def __init__(self, active=True):
        self.active = active

    def check(self):
        pass


class StubClipboard:
    def __init__(self, fail=None):
        self.copies, self.fail = [], fail

    def copy(self, text, concealed=False):
        if self.fail:
            raise self.fail
        self.copies.append((text, concealed))


class PortalActiveTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.config = Path(directory.name) / 'linux.json'

    def test_portal_desktops_only(self):
        self.assertTrue(clipboard_copy.portal_active(None, GNOME))
        self.assertTrue(clipboard_copy.portal_active(None, KDE))
        self.assertFalse(clipboard_copy.portal_active(None, HYPRLAND))
        self.assertFalse(clipboard_copy.portal_active(None, {'XDG_CURRENT_DESKTOP': 'GNOME', 'XDG_SESSION_TYPE': 'x11'}))
        self.assertFalse(clipboard_copy.portal_active(None, {}))

    def test_config_override_wins(self):
        self.config.write_text(json.dumps({'desktop': {'delivery': 'hyprland'}}))
        self.assertFalse(clipboard_copy.portal_active(self.config, GNOME))
        self.config.write_text(json.dumps({'desktop': {'delivery': 'portal'}}))
        self.assertTrue(clipboard_copy.portal_active(self.config, HYPRLAND))

    def test_unreadable_or_invalid_config_means_auto(self):
        self.assertTrue(clipboard_copy.portal_active(self.config, GNOME))
        self.config.write_text('{"desktop": {"delivery": "bogus"}}')
        self.assertTrue(clipboard_copy.portal_active(self.config, GNOME))
        self.config.write_text('[]')
        self.assertFalse(clipboard_copy.portal_active(self.config, HYPRLAND))


class CopyViaPortalTests(unittest.TestCase):
    def test_sends_a_concealed_copy_to_the_daemon(self):
        calls = []

        def request(action, **fields):
            calls.append((action, fields))
            return {'ok': True}
        self.assertTrue(clipboard_copy.copy_via_portal('hello', request, env=GNOME))
        self.assertEqual(calls, [('copy', {'text': 'hello', 'concealed': True,
                                          'reply_timeout': clipboard_copy.COPY_REPLY_SECONDS})])

    def test_hyprland_never_contacts_the_daemon(self):
        request = mock.Mock()
        self.assertFalse(clipboard_copy.copy_via_portal('hello', request, env=HYPRLAND))
        request.assert_not_called()

    def test_failures_fall_back(self):
        for reply in ({'ok': False, 'error': 'copy_unsupported'}, {'error': 'invalid_command'}, None, 'x'):
            self.assertFalse(clipboard_copy.copy_via_portal('t', lambda action, **f: reply, env=GNOME))
        for error in (OSError('down'), ValueError('bad')):
            def request(action, **fields):
                raise error
            self.assertFalse(clipboard_copy.copy_via_portal('t', request, env=GNOME))


class PortalDeliveryCopyTests(unittest.TestCase):
    def delivery(self, active=True, clipboard=None):
        clipboard = clipboard or StubClipboard()
        return delivery_portal.PortalDelivery({}, StubRemote(active), clipboard), clipboard

    def test_copy_text_offers_the_hint_by_default(self):
        delivery, clipboard = self.delivery()
        self.assertTrue(delivery.copy_text('words'))
        self.assertTrue(delivery.copy_text('plain', concealed=False))
        self.assertEqual(clipboard.copies, [('words', True), ('plain', False)])

    def test_no_grant_or_portal_error_is_false(self):
        delivery, clipboard = self.delivery(active=False)
        self.assertFalse(delivery.copy_text('words'))
        self.assertEqual(clipboard.copies, [])
        delivery, _ = self.delivery(clipboard=StubClipboard(fail=portal.PortalError('gone')))
        self.assertFalse(delivery.copy_text('words'))


class DaemonCopyTests(unittest.TestCase):
    def test_delivery_without_a_clipboard_session_is_unsupported(self):
        session = mock.Mock(delivery=object())
        self.assertEqual(desktop.copy_through_delivery(session, 'x', True), {'ok': False, 'error': 'copy_unsupported'})

    def test_portal_delivery_copies(self):
        delivery = delivery_portal.PortalDelivery({}, StubRemote(), StubClipboard())
        session = mock.Mock(delivery=delivery)
        self.assertEqual(desktop.copy_through_delivery(session, 'x', True), {'ok': True})
        self.assertEqual(delivery.clipboard.copies, [('x', True)])

    def test_bad_fields_are_rejected(self):
        delivery = delivery_portal.PortalDelivery({}, StubRemote(), StubClipboard())
        session = mock.Mock(delivery=delivery)
        self.assertFalse(desktop.copy_through_delivery(session, 5, True)['ok'])
        self.assertFalse(desktop.copy_through_delivery(session, 'x', 'yes')['ok'])
        self.assertEqual(delivery.clipboard.copies, [])


class CopyLastPortalTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.recovery = root / 'recovery'
        self.recovery.mkdir(mode=0o700)
        newest = make_take(self.recovery, hexid(2), stamp(20, 9), None, 1)
        (newest / 'transcript.txt').write_text('Newest line.')
        self.config = root / 'linux.json'
        self.config.write_text('{}')
        self.root = root
        self.requests = []

    def run_verb(self, reply, env):
        def ask(action, identity=None, **fields):
            self.requests.append((action, fields))
            return reply
        context = desktop.CliContext(config=self.config, recovery=self.recovery, imports=self.root / 'i',
                                     runtime=self.root / 'run', socket=self.root / 'run/session.sock', request=ask)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), mock.patch.dict(clipboard_copy.os.environ, env, clear=True):
            code = cli_automation.run(argparse.Namespace(action='copy-last'), context)
        return code, out.getvalue()

    def test_portal_desktop_copies_through_the_daemon_not_wl_copy(self):
        with mock.patch.object(cli_automation.subprocess, 'run') as run:
            code, out = self.run_verb({'ok': True}, GNOME)
        self.assertEqual(code, 0)
        run.assert_not_called()
        self.assertEqual(self.requests[0][0], 'copy')
        self.assertEqual((self.requests[0][1]['text'], self.requests[0][1]['concealed']), ('Newest line.', True))
        self.assertEqual(json.loads(out)['message'], 'Copied to clipboard')

    def test_a_refused_portal_copy_falls_back_to_wl_copy(self):
        with mock.patch.object(cli_automation.shutil, 'which', return_value='/usr/bin/wl-copy'), \
                mock.patch.object(cli_automation.subprocess, 'run') as run:
            code, _ = self.run_verb({'ok': False}, KDE)
        self.assertEqual(code, 0)
        self.assertEqual(run.call_args.args[0], cli_automation.COPY)

    def test_hyprland_makes_no_daemon_request(self):
        with mock.patch.object(cli_automation.shutil, 'which', return_value='/usr/bin/wl-copy'), \
                mock.patch.object(cli_automation.subprocess, 'run'):
            code, _ = self.run_verb({'ok': True}, HYPRLAND)
        self.assertEqual((code, self.requests), (0, []))


if __name__ == '__main__':
    unittest.main()
