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
        self.notifier = lambda summary, body='': self.messages.append((summary, body))

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
        self.assertIn('Super+Shift+T', self.messages[-1][1])

    def test_without_omarchy_only_speech_is_prepared(self):
        calls = []
        firstrun.run_first(setup_main=lambda argv: calls.append(argv) or 0, notifier=self.notifier)
        self.assertIn('--skip-plugin', calls[0])
        self.assertNotIn('Super+Shift+T', self.messages[-1][1])

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


if __name__ == '__main__':
    unittest.main()
