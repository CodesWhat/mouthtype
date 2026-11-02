import json
import os
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock
import shutil

from desktop import HyprlandDelivery
from hyprland_ipc import HyprlandIPC, IPCError, IPCTimeout

TARGET = {'address': '0xabc', 'class': 'editor', 'pid': 42}


class FakeHyprland:
    """A unix socket that answers one request per connection, like Hyprland's request socket."""
    def __init__(self, directory, signature='sig', replies=None, mode='reply'):
        self.dir = Path(directory) / 'hypr' / signature
        self.dir.mkdir(parents=True)
        self.path = str(self.dir / '.socket.sock')
        self.replies, self.mode, self.requests = replies or {}, mode, []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(8)
        self.server.settimeout(.1)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with connection:
                request = connection.recv(65536).decode()
                self.requests.append(request)
                if self.mode == 'hang':
                    self.stop.wait(2)
                elif self.mode == 'reply':
                    reply = self.replies.get(request)
                    if reply is None and request.startswith('/dispatch'):
                        reply = 'ok'
                    connection.sendall((reply if reply is not None else 'unknown request').encode())

    def close(self):
        self.stop.set()
        self.server.close()
        self.thread.join(2)


class IPCTestCase(unittest.TestCase):
    def serve(self, **kwargs):
        directory = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(directory, ignore_errors=True))
        fake = FakeHyprland(directory, **kwargs)
        self.addCleanup(fake.close)
        return fake, {'HYPRLAND_INSTANCE_SIGNATURE': 'sig', 'XDG_RUNTIME_DIR': directory}


class SocketClientTests(IPCTestCase):
    def test_request_returns_reply_and_sends_exact_command(self):
        fake, env = self.serve(replies={'j/activewindow': json.dumps(TARGET)})
        self.assertEqual(json.loads(HyprlandIPC(env).request('j/activewindow', .5)), TARGET)
        self.assertEqual(fake.requests, ['j/activewindow'])

    def test_missing_signature_or_socket_is_unsent_error(self):
        for env in ({}, {'HYPRLAND_INSTANCE_SIGNATURE': 'nope', 'XDG_RUNTIME_DIR': tempfile.gettempdir()},
                    {'HYPRLAND_INSTANCE_SIGNATURE': '../x'}):
            with self.subTest(env=env), self.assertRaises(IPCError) as caught:
                HyprlandIPC(env).request('j/locked', .5)
            self.assertFalse(caught.exception.sent)

    def test_tmp_fallback_path(self):
        signature = 'mt-test-%d' % os.getpid()
        root = Path('/tmp/hypr')
        existed = root.exists()
        fake = FakeHyprland('/tmp', signature=signature)
        try:
            ipc = HyprlandIPC({'HYPRLAND_INSTANCE_SIGNATURE': signature})
            self.assertEqual(ipc.socket_path(), fake.path)
        finally:
            fake.close()
            os.unlink(fake.path)
            os.rmdir(fake.dir)
            if not existed:
                try:
                    root.rmdir()
                except OSError:
                    pass

    def test_hang_times_out_quickly(self):
        fake, env = self.serve(mode='hang')
        started = time.monotonic()
        with self.assertRaises(IPCTimeout) as caught:
            HyprlandIPC(env).request('j/activewindow', .2)
        self.assertLess(time.monotonic() - started, 1)
        self.assertTrue(caught.exception.sent)

    def test_dropped_connection_returns_empty_reply(self):
        fake, env = self.serve(mode='close')
        self.assertEqual(HyprlandIPC(env).request('j/locked', .5), '')


def spawn_recorder():
    calls = []
    def run(argv, **kwargs):
        calls.append(list(argv))
        return type('Result', (), {'returncode': 0, 'stdout': '', 'stderr': 'ok' if argv[0] == 'hyprctl' else ''})()
    return calls, run


class DeliveryOverSocketTests(IPCTestCase):
    def delivery(self, env, config=None, ipc=True, **kwargs):
        calls, run = spawn_recorder()
        with mock.patch('subprocess.run', run):
            delivery = HyprlandDelivery({'mode': 'paste', 'any_window': True, 'allow_unknown_secure_field': True,
                                         'restore_clipboard': False, **(config or {})},
                                        ipc=HyprlandIPC(env) if ipc else None, **kwargs)
        delivery.ipc = HyprlandIPC(env) if ipc else None
        delivery.settle_seconds = 0
        return delivery, calls

    def replies(self):
        return {'j/locked': json.dumps({'locked': False}), 'j/activewindow': json.dumps({**TARGET, 'title': 'private'})}

    def test_snapshot_reads_activewindow_json_without_spawning(self):
        fake, env = self.serve(replies=self.replies())
        delivery, calls = self.delivery(env)
        self.assertEqual(delivery.snapshot(), TARGET)
        self.assertEqual(fake.requests, ['j/locked', 'j/activewindow'])
        self.assertEqual(calls, [])

    def test_locked_screen_refuses_snapshot(self):
        fake, env = self.serve(replies={**self.replies(), 'j/locked': json.dumps({'locked': True})})
        delivery, calls = self.delivery(env)
        self.assertIsNone(delivery.snapshot())
        self.assertEqual(calls, [])

    def test_unknown_locked_request_matches_hyprctl_and_refuses(self):
        fake, env = self.serve(replies={'j/activewindow': json.dumps(TARGET)})
        delivery, _ = self.delivery(env)
        self.assertIsNone(delivery.snapshot())

    def test_window_class_uses_socket_and_keeps_half_second_limit(self):
        fake, env = self.serve(replies=self.replies())
        delivery, calls = self.delivery(env, {'mode': 'recover'})
        self.assertEqual(delivery.window_class(), 'editor')
        self.assertEqual(calls, [])
        slow, env = self.serve(mode='hang')
        delivery, calls = self.delivery(env, {'mode': 'recover'})
        started = time.monotonic()
        self.assertIsNone(delivery.window_class())
        self.assertLess(time.monotonic() - started, .9)
        self.assertEqual(calls, [])

    def test_socket_error_falls_back_to_hyprctl(self):
        calls = []
        def run(argv, **kwargs):
            calls.append((argv, kwargs['timeout']))
            body = {'locked': json.dumps({'locked': False}), 'activewindow': json.dumps(TARGET)}[argv[-1]]
            return type('Result', (), {'stdout': body})()
        delivery = HyprlandDelivery({'mode': 'paste'}, run=run, ipc=HyprlandIPC({}))
        self.assertEqual(delivery.snapshot(), TARGET)
        self.assertEqual([argv for argv, _ in calls], [['hyprctl', '-j', 'locked'], ['hyprctl', '-j', 'activewindow']])
        self.assertTrue(all(timeout <= .5 for _, timeout in calls))

    def test_read_timeout_does_not_double_the_budget_with_hyprctl(self):
        fake, env = self.serve(mode='hang')
        calls = []
        delivery = HyprlandDelivery({'mode': 'paste'}, run=lambda *a, **k: calls.append(a), ipc=HyprlandIPC(env))
        self.assertIsNone(delivery.snapshot())
        self.assertEqual(calls, [])

    def test_dispatch_goes_over_socket_exactly_as_hyprctl_sends_it(self):
        fake, env = self.serve(replies=self.replies())
        delivery, calls = self.delivery(env)
        delivery.clipboard = lambda: 'text'
        self.assertEqual(delivery.submit('text', TARGET), 'unknown')
        dispatches = [request for request in fake.requests if request.startswith('/dispatch ')]
        self.assertEqual(dispatches, ['/dispatch hl.dsp.send_shortcut({mods="CTRL", key="v", window="address:0xabc"})'])
        self.assertFalse([argv for argv in calls if argv[0] == 'hyprctl'])

    def test_dispatch_error_reply_tries_legacy_form(self):
        fake, env = self.serve(replies={**self.replies(),
                                        '/dispatch hl.dsp.send_shortcut({mods="CTRL", key="v", window="address:0xabc"})': 'error: unknown'})
        delivery, calls = self.delivery(env)
        delivery.clipboard = lambda: 'text'
        self.assertEqual(delivery.submit('text', TARGET), 'unknown')
        self.assertEqual([r for r in fake.requests if r.startswith('/dispatch ')][1], '/dispatch sendshortcut CTRL,v,address:0xabc')

    def test_uncertain_dispatch_reply_is_unknown_and_never_retried(self):
        dispatch = '/dispatch hl.dsp.send_shortcut({mods="CTRL", key="v", window="address:0xabc"})'
        for reply in ('', 'o'):
            with self.subTest(reply=reply):
                fake, env = self.serve(replies={**self.replies(), dispatch: reply})
                delivery, calls = self.delivery(env)
                delivery.clipboard = lambda: 'text'
                self.assertEqual(delivery.submit('text', TARGET), 'unknown')
                self.assertEqual(len([r for r in fake.requests if r.startswith('/dispatch ')]), 1)
                self.assertFalse([argv for argv in calls if argv[0] in ('hyprctl', 'wtype')])

    def test_explicit_error_reply_may_fall_back(self):
        fake, env = self.serve(replies={**self.replies(),
                                        '/dispatch hl.dsp.send_shortcut({mods="CTRL", key="v", window="address:0xabc"})': 'Invalid dispatcher'})
        delivery, calls = self.delivery(env)
        delivery.clipboard = lambda: 'text'
        self.assertEqual(delivery.submit('text', TARGET), 'unknown')
        self.assertEqual(len([r for r in fake.requests if r.startswith('/dispatch ')]), 2)

    def test_dispatch_timeout_is_unknown_and_never_retried(self):
        fake, env = self.serve(replies=self.replies())
        delivery, calls = self.delivery(env)
        delivery.clipboard = lambda: 'text'
        original = delivery.ipc.request
        def request(command, timeout):
            if command.startswith('/dispatch'):
                fake.requests.append(command)
                raise IPCTimeout('slow', sent=True)
            return original(command, timeout)
        delivery.ipc.request = request
        self.assertEqual(delivery.submit('text', TARGET), 'unknown')
        self.assertEqual(len([r for r in fake.requests if r.startswith('/dispatch ')]), 1)
        self.assertFalse([argv for argv in calls if argv[0] in ('hyprctl', 'wtype')])

    def test_dispatch_without_socket_falls_back_to_hyprctl(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            if argv[0] == 'hyprctl' and argv[1] == '-j':
                return type('Result', (), {'stdout': json.dumps({'locked': False} if argv[-1] == 'locked' else TARGET)})()
            return type('Result', (), {'returncode': 0, 'stdout': 'ok', 'stderr': ''})()
        delivery = HyprlandDelivery({'mode': 'paste', 'any_window': True, 'allow_unknown_secure_field': True,
                                     'restore_clipboard': False}, run=run, ipc=HyprlandIPC({}))
        delivery.settle_seconds = 0
        delivery.clipboard = lambda: 'text'
        self.assertEqual(delivery.submit('text', TARGET), 'unknown')
        self.assertEqual([argv[:2] for argv in calls if argv[1] == 'dispatch'], [['hyprctl', 'dispatch']])

    def hyprctl_dispatch_delivery(self, stdout, stderr='', returncode=0):
        calls = []
        def run(argv, **kwargs):
            calls.append(list(argv))
            if argv[:2] == ['hyprctl', '-j']:
                return type('Result', (), {'stdout': json.dumps({'locked': False} if argv[-1] == 'locked' else TARGET)})()
            return type('Result', (), {'returncode': returncode, 'stdout': stdout, 'stderr': stderr})()
        delivery = HyprlandDelivery({'mode': 'paste', 'any_window': True, 'allow_unknown_secure_field': True,
                                     'restore_clipboard': False}, run=run)
        delivery.settle_seconds = 0
        delivery.clipboard = lambda: 'text'
        return delivery, calls

    def test_hyprctl_dispatch_with_empty_or_truncated_reply_is_unknown_and_never_retried(self):
        for stdout, stderr in (('', ''), ('o', ''), ('', 'o')):
            with self.subTest(stdout=stdout, stderr=stderr):
                delivery, calls = self.hyprctl_dispatch_delivery(stdout, stderr)
                self.assertEqual(delivery.submit('text', TARGET), 'unknown')
                self.assertEqual(len([a for a in calls if a[:2] == ['hyprctl', 'dispatch']]), 1)
                self.assertFalse([a for a in calls if a[0] == 'wtype'])

    def test_hyprctl_dispatch_with_explicit_error_reply_may_fall_back(self):
        delivery, calls = self.hyprctl_dispatch_delivery('Invalid dispatcher', '', 0)
        self.assertEqual(delivery.submit('text', TARGET), 'unknown')
        self.assertEqual(len([a for a in calls if a[:2] == ['hyprctl', 'dispatch']]), 2)
        self.assertTrue([a for a in calls if a[0] == 'wtype'])

    def test_failure_before_the_hyprctl_dispatch_runs_may_fall_back(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(list(argv))
            if argv[:2] == ['hyprctl', '-j']:
                return type('Result', (), {'stdout': json.dumps({'locked': False} if argv[-1] == 'locked' else TARGET)})()
            if argv[:2] == ['hyprctl', 'dispatch']:
                raise FileNotFoundError('hyprctl')
            return type('Result', (), {'returncode': 0})()
        delivery = HyprlandDelivery({'mode': 'paste', 'any_window': True, 'allow_unknown_secure_field': True,
                                     'restore_clipboard': False}, run=run)
        delivery.settle_seconds = 0
        delivery.clipboard = lambda: 'text'
        self.assertEqual(delivery.submit('text', TARGET), 'unknown')
        self.assertTrue([a for a in calls if a[0] == 'wtype'])

    def stop_path_spawns(self, env, verified, ipc):
        delivery, calls = self.delivery(env, ipc=ipc)
        delivery.clipboard = lambda: 'text'
        counted = []
        def run(argv, **kwargs):
            counted.append(argv[0])
            if argv[0] == 'hyprctl' and argv[1] == '-j':
                return type('Result', (), {'stdout': json.dumps({'locked': False} if argv[-1] == 'locked' else TARGET)})()
            return type('Result', (), {'returncode': 0, 'stdout': 'ok', 'stderr': ''})()
        delivery.run = run
        # What _finish does before delivering, then the delivery itself.
        self.assertEqual(delivery.snapshot(), TARGET)
        self.assertEqual(delivery.submit('text', TARGET, verified=verified), 'unknown')
        return counted

    def test_stop_path_spawn_counts_drop(self):
        fake, env = self.serve(replies=self.replies())
        before = self.stop_path_spawns(env, verified=False, ipc=False)
        after = self.stop_path_spawns(env, verified=True, ipc=True)
        self.assertEqual(before.count('hyprctl'), 7)
        self.assertEqual(after.count('hyprctl'), 0)
        self.assertEqual(after, ['wl-copy'])
        self.assertEqual(before.count('hyprctl') + before.count('wl-copy'), 8)

    def test_verified_paste_still_checks_focus_after_wl_copy(self):
        fake, env = self.serve(replies=self.replies())
        delivery, calls = self.delivery(env)
        delivery.clipboard = lambda: 'text'
        moved = {**TARGET, 'address': '0xdef'}
        original = delivery.ipc.request
        def request(command, timeout):
            if command == 'j/activewindow' and any(argv[0] == 'wl-copy' for argv in calls):
                return json.dumps(moved)
            return original(command, timeout)
        delivery.ipc.request = request
        delivery.run = lambda argv, **kwargs: calls.append(list(argv)) or type('Result', (), {'returncode': 0})()
        self.assertEqual(delivery.submit('text', TARGET, verified=True), 'target_changed')
        self.assertFalse([r for r in fake.requests if r.startswith('/dispatch')])

    def test_unverified_paste_still_checks_before_touching_clipboard(self):
        fake, env = self.serve(replies=self.replies())
        delivery, calls = self.delivery(env)
        self.assertEqual(delivery.submit('text', {**TARGET, 'address': '0x999'}), 'target_changed')
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
