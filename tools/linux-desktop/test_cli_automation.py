import argparse
import contextlib
import io
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import unittest
from unittest import mock

import cli_automation
import desktop
from test_stats import hexid, make_take, stamp


class FakeDelivery:
    outcome = 'unknown'
    snapshot_value = {'address': '0x1', 'class': 'kitty', 'pid': 7}
    calls = []
    during_submit = None

    def __init__(self, config):
        self.config = config
        self.restore_thread = None

    def snapshot(self):
        return self.snapshot_value

    def submit(self, text, target, cancelled=None):
        FakeDelivery.calls.append((text, target, cancelled))
        if FakeDelivery.during_submit:
            FakeDelivery.during_submit(cancelled)
        return FakeDelivery.outcome


class AutomationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.recovery = self.root / 'recovery'
        self.recovery.mkdir(mode=0o700)
        make_take(self.recovery, hexid(1), stamp(19, 9), 3, 1)
        newest = make_take(self.recovery, hexid(2), stamp(20, 9), None, 1)
        (newest / 'transcript.txt').write_text('Newest line.')
        self.config = self.root / 'linux.json'
        self.write_config({'mode': 'paste', 'allowed_classes': ['kitty']})
        self.status = {'state': 'idle'}
        FakeDelivery.outcome = 'unknown'
        FakeDelivery.snapshot_value = {'address': '0x1', 'class': 'kitty', 'pid': 7}
        FakeDelivery.calls = []
        FakeDelivery.during_submit = None
        patch = mock.patch.object(desktop, 'HyprlandDelivery', FakeDelivery)
        patch.start()
        self.addCleanup(patch.stop)

    def write_config(self, delivery):
        self.config.write_text(json.dumps({'engine_config': 'engine.json', 'delivery': delivery}))

    def context(self, request=None):
        def ask(action, identity=None, **fields):
            if isinstance(self.status, Exception):
                raise self.status
            return self.status
        return desktop.CliContext(config=self.config, recovery=self.recovery, imports=self.root / 'imports',
                                  runtime=self.root / 'run', socket=self.root / 'run/session.sock',
                                  request=request or ask)

    def run_verb(self, verb):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli_automation.run(argparse.Namespace(action=verb), self.context())
        return code, out.getvalue(), err.getvalue()

    def test_verbs_register(self):
        parser = argparse.ArgumentParser()
        commands = parser.add_subparsers(dest='action')
        cli_automation.register(commands)
        self.assertEqual(set(commands.choices), {'copy-last', 'paste-last'})

    def test_loader_picks_both_verbs_up(self):
        parser = argparse.ArgumentParser()
        commands = parser.add_subparsers(dest='action')
        owners = desktop.register_cli_modules(commands, desktop.load_cli_modules())
        self.assertEqual({'copy-last', 'paste-last', 'stats'} - set(owners), set())

    def test_copy_last_copies_the_newest_transcript(self):
        with mock.patch.object(cli_automation.shutil, 'which', return_value='/usr/bin/wl-copy'), \
                mock.patch.object(cli_automation.subprocess, 'run') as run:
            code, out, _ = self.run_verb('copy-last')
        self.assertEqual(code, 0)
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0], ['wl-copy', '--type', 'text/plain;charset=utf-8'])
        self.assertEqual(run.call_args.kwargs['input'], b'Newest line.')
        self.assertEqual(json.loads(out)['id'], hexid(2))

    def test_copy_last_reports_a_missing_wl_copy(self):
        with mock.patch.object(cli_automation.shutil, 'which', return_value=None):
            code, _, err = self.run_verb('copy-last')
        self.assertEqual((code, json.loads(err)['error']), (2, 'wl_copy_missing'))

    def test_copy_last_reports_a_failed_copy(self):
        with mock.patch.object(cli_automation.shutil, 'which', return_value='/usr/bin/wl-copy'), \
                mock.patch.object(cli_automation.subprocess, 'run', side_effect=subprocess.TimeoutExpired('wl-copy', 5)):
            code, _, err = self.run_verb('copy-last')
        self.assertEqual((code, json.loads(err)['error']), (2, 'copy_failed'))

    def test_no_saved_dictation(self):
        for child in list(self.recovery.iterdir()):
            (child / 'transcript.txt').unlink(missing_ok=True)
        code, _, err = self.run_verb('paste-last')
        self.assertEqual((code, json.loads(err)['error']), (2, 'no_dictation'))

    def test_paste_last_goes_through_the_daemon_delivery_with_a_cancel_event(self):
        code, out, _ = self.run_verb('paste-last')
        self.assertEqual(code, 0)
        text, target, cancelled = FakeDelivery.calls[0]
        self.assertEqual((text, target), ('Newest line.', FakeDelivery.snapshot_value))
        self.assertIsInstance(cancelled, threading.Event)
        self.assertFalse(cancelled.is_set())
        result = json.loads(out)
        self.assertEqual((result['ok'], result['id'], result['outcome']), (True, hexid(2), 'unknown'))

    def test_paste_last_is_refused_when_pasting_is_off(self):
        self.write_config({'mode': 'recover'})
        code, _, err = self.run_verb('paste-last')
        self.assertEqual((code, json.loads(err)['error']), (2, 'delivery_disabled'))
        self.assertEqual(FakeDelivery.calls, [])

    def test_paste_last_is_refused_with_a_bad_config(self):
        self.config.write_text('{')
        code, _, err = self.run_verb('paste-last')
        self.assertEqual((code, json.loads(err)['error']), (2, 'config_unavailable'))

    def test_paste_last_waits_out_a_busy_daemon(self):
        for state in ('recording', 'transcribing', 'cancelling'):
            self.status = {'state': state}
            code, _, err = self.run_verb('paste-last')
            self.assertEqual((code, json.loads(err)['error']), (2, 'busy'))
        self.assertEqual(FakeDelivery.calls, [])

    def test_paste_last_works_without_the_daemon(self):
        self.status = FileNotFoundError('no socket')
        code, _, _ = self.run_verb('paste-last')
        self.assertEqual(code, 0)
        self.assertEqual(len(FakeDelivery.calls), 1)

    def test_paste_last_needs_a_target(self):
        FakeDelivery.snapshot_value = None
        code, _, err = self.run_verb('paste-last')
        self.assertEqual((code, json.loads(err)['error']), (2, 'no_target'))
        self.assertEqual(FakeDelivery.calls, [])

    def test_refused_outcomes_are_errors(self):
        for outcome, code_name in (('recover_only', 'not_delivered'), ('target_changed', 'not_delivered'),
                                   ('unsupported_text', 'not_delivered'), ('not_attempted', 'cancelled')):
            FakeDelivery.outcome = outcome
            code, out, err = self.run_verb('paste-last')
            self.assertEqual(code, 2)
            self.assertEqual(out, '')
            self.assertEqual((json.loads(err)['error'], json.loads(err)['outcome']), (code_name, outcome))

    def test_interrupt_sets_the_cancel_event_and_handlers_are_restored(self):
        seen = []

        def interrupt(cancelled):
            signal.raise_signal(signal.SIGTERM)
            seen.append(cancelled.is_set())
        FakeDelivery.during_submit = interrupt
        before = signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGINT)
        self.run_verb('paste-last')
        self.assertEqual(seen, [True])
        self.assertEqual((signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGINT)), before)

    def test_restore_thread_is_joined(self):
        done = threading.Event()
        thread = threading.Thread(target=done.wait, args=(0.2,))
        thread.start()
        original = FakeDelivery.__init__

        def init(self, config):
            original(self, config)
            self.restore_thread = thread
        with mock.patch.object(FakeDelivery, '__init__', init):
            self.run_verb('paste-last')
        self.assertFalse(thread.is_alive())


if __name__ == '__main__':
    unittest.main()
