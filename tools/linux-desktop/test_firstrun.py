import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

import firstrun


class FirstRunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        for patcher in (mock.patch.object(firstrun, 'home', lambda: self.home),
                        mock.patch.dict(os.environ, {'XDG_STATE_HOME': ''}),
                        mock.patch.object(firstrun.sys, 'platform', 'linux')):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.messages = []
        self.calls = []

        def notifier(summary, body='', *, percent=None, replace_id=None):
            self.messages.append((summary, body))
            self.calls.append({'summary': summary, 'percent': percent, 'replace_id': replace_id})
            return 7
        self.notifier = notifier

    def omarchy(self):
        (self.home / '.config/omarchy').mkdir(parents=True)
        (self.home / '.config/omarchy/shell.json').write_text('{}')

    def prepared_speech(self):
        path = self.home / '.local/share/mouthtype/speech-candidate/linux.json'
        path.parent.mkdir(parents=True)
        path.write_text('{}')

    def state(self):
        return json.loads(firstrun.state_path().read_text())

    def test_unset_runs_the_setup_steps_with_both_shortcuts_and_marks_done(self):
        self.omarchy()
        calls = []
        status = firstrun.run_first(setup_main=lambda argv: calls.append(argv) or 0, notifier=self.notifier)
        self.assertEqual(status, 0)
        self.assertEqual(calls, [['--shortcut', 'toggle']])
        self.assertEqual(self.state()['state'], 'done')
        self.assertEqual([m[0] for m in self.messages], ['Setting up Mouthtype', 'Mouthtype is ready'])

    def test_ready_message_names_only_the_keys_that_were_bound(self):
        self.omarchy()
        bindings = self.home / '.config/hypr/bindings.lua'
        bindings.parent.mkdir(parents=True)
        bindings.write_text('-- Mouthtype Omarchy plugin shortcut: begin\nx\n-- Mouthtype Omarchy plugin shortcut: end\n')
        firstrun.run_first(setup_main=lambda argv: 0, notifier=self.notifier)
        self.assertIn('Super+Alt+M', self.messages[-1][1])
        self.assertNotIn('Super+Shift+T', self.messages[-1][1])

    def test_without_omarchy_only_speech_is_prepared(self):
        calls = []
        firstrun.run_first(setup_main=lambda argv: calls.append(argv) or 0, notifier=self.notifier)
        self.assertIn('--skip-plugin', calls[0])

        self.assertIn('Pick a dictation key', self.messages[-1][1])

    def test_a_complete_setup_does_nothing_and_is_remembered(self):
        self.omarchy()
        self.prepared_speech()
        (self.home / '.config/omarchy/plugins/dstahl.mouthtype').mkdir(parents=True)
        setup = mock.Mock(return_value=0)
        self.assertEqual(firstrun.run_first(setup_main=setup, notifier=self.notifier), 0)
        setup.assert_not_called()
        self.assertEqual(self.messages, [])
        self.assertEqual(self.state()['state'], 'done')

    def test_missing_plugin_alone_triggers_setup_on_omarchy(self):
        self.omarchy()
        self.prepared_speech()
        self.assertEqual(firstrun.needs_setup(), 'no bar plugin')

    def test_done_and_uninstalled_are_never_redone(self):
        for state in ('done', 'uninstalled'):
            firstrun.record(state)
            setup = mock.Mock(return_value=0)
            self.assertEqual(firstrun.run_first(setup_main=setup, notifier=self.notifier), 0)
            setup.assert_not_called()

    def test_failure_notifies_with_the_reason_and_exits_nonzero_without_looping(self):
        def failing(argv):
            print('Could not download the model', file=sys.stderr)
            return 2
        self.assertEqual(firstrun.run_first(setup_main=failing, notifier=self.notifier), 1)
        self.assertEqual(self.state()['state'], 'failed')
        self.assertEqual(self.state()['attempts'], 1)
        self.assertEqual(self.state()['error'], 'Could not download the model')
        self.assertEqual(self.messages[-1][0], 'Mouthtype setup failed')
        self.assertIn('next login', self.messages[-1][1])

    def test_stops_retrying_after_the_attempt_cap(self):
        calls = []
        for _ in range(firstrun.MAX_ATTEMPTS + 2):
            firstrun.run_first(setup_main=lambda argv: calls.append(1) or 2, notifier=self.notifier)
        self.assertEqual(len(calls), firstrun.MAX_ATTEMPTS)
        self.assertIn('mouthtype-linux-setup', self.messages[-1][1])

    def test_a_crash_inside_setup_is_a_failure_not_a_traceback(self):
        def boom(argv):
            raise OSError('disk full')
        self.assertEqual(firstrun.run_first(setup_main=boom, notifier=self.notifier), 1)
        self.assertIn('disk full', self.state()['error'])

    def test_a_second_run_while_one_is_in_progress_yields(self):
        import fcntl
        firstrun.state_dir().mkdir(parents=True)
        with open(firstrun.state_dir() / 'firstrun.lock', 'w') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            setup = mock.Mock(return_value=0)
            self.assertEqual(firstrun.run_first(setup_main=setup, notifier=self.notifier), 0)
        setup.assert_not_called()

    def progress_run(self, readings):
        """Run first-run with a fake setup that finishes once the fake clock has fed it every reading."""
        import threading
        progress = firstrun.speech_progress_path()
        progress.parent.mkdir(parents=True, exist_ok=True)
        finished, pending = threading.Event(), list(readings)

        def sleep(_):
            if pending:
                progress.write_text(json.dumps({'state': 'downloading', 'bytes_done': pending.pop(0), 'bytes_total': 1000}))
            if not pending:
                finished.set()

        def setup(argv):
            finished.wait(5)
            return 0
        return firstrun.run_first(setup_main=setup, notifier=self.notifier, sleep=sleep)

    def test_download_progress_updates_one_notification_monotonically(self):
        self.omarchy()
        self.assertEqual(self.progress_run([20, 30, 100, 400, 390, 1000]), 0)
        updates = [c for c in self.calls if c['summary'] == 'Setting up Mouthtype']
        self.assertEqual(updates[0], {'summary': 'Setting up Mouthtype', 'percent': 0, 'replace_id': None})
        percents = [c['percent'] for c in updates]
        self.assertEqual(percents, [0, 10, 40, 100])
        self.assertTrue(all(c['replace_id'] == 7 for c in updates[1:]))

    def test_final_message_replaces_the_progress_notification(self):
        self.omarchy()
        self.progress_run([500, 1000])
        self.assertEqual(self.calls[-1]['summary'], 'Mouthtype is ready')
        self.assertEqual(self.calls[-1]['replace_id'], 7)
        self.assertIsNone(self.calls[-1]['percent'])

    def test_failure_message_replaces_the_progress_notification(self):
        self.omarchy()
        failing = lambda argv: 2
        firstrun.run_first(setup_main=failing, notifier=self.notifier, sleep=lambda _: None)
        self.assertEqual(self.calls[-1]['summary'], 'Mouthtype setup failed')
        self.assertEqual(self.calls[-1]['replace_id'], 7)

    def test_without_an_id_the_progress_message_is_not_updated(self):
        self.omarchy()
        sent = []
        quiet = lambda summary, body='', *, percent=None, replace_id=None: sent.append(summary)
        firstrun.run_first(setup_main=lambda argv: 0, notifier=quiet, sleep=lambda _: None)
        self.assertEqual(sent, ['Setting up Mouthtype', 'Mouthtype is ready'])

    def test_notify_passes_the_progress_hint_and_replace_id(self):
        seen = []

        def run(command, **kwargs):
            seen.append(command)
            return mock.Mock(stdout='42\n')
        with mock.patch.object(firstrun.shutil, 'which', return_value='/usr/bin/notify-send'):
            self.assertEqual(firstrun.notify('t', 'b', percent=35, replace_id=9, run=run), 42)
        self.assertIn('--replace-id=9', seen[0])
        self.assertEqual(seen[0][seen[0].index('-h') + 1], 'int:value:35')

    def test_notify_without_notify_send_does_nothing(self):
        with mock.patch.object(firstrun.shutil, 'which', return_value=None):
            self.assertIsNone(firstrun.notify('t', run=mock.Mock(side_effect=AssertionError)))


if __name__ == '__main__':
    unittest.main()
