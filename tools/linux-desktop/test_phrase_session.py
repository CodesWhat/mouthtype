import json
from pathlib import Path
import tempfile
import unittest

import desktop
from test_desktop import Capture, Delivery, Engine


class PhraseSessionFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.path = self.root / 'phrases.json'
        self.write('First Street')
        self.capture, self.engine, self.delivery = Capture(), Engine('my address.'), Delivery()
        self.session = desktop.Session(self.capture, self.engine, self.delivery, self.root / 'recovery')
        self.session.phrases = self.path

    def tearDown(self):
        self.session.close()
        self.temp.cleanup()

    def write(self, expansion):
        self.path.write_text(json.dumps([{'trigger': 'my address', 'expansion': expansion}]))

    def finish(self):
        self.session.command('stop')
        self.session.wait()

class PhraseSessionTests(PhraseSessionFixture, unittest.TestCase):
    def test_phrase_snapshot_delivers_once_and_preserves_raw_recognition(self):
        self.session.command('start')
        self.write('Second Street')
        self.finish()
        take = self.session.take
        self.assertEqual(self.delivery.calls[0][0], 'First Street.')
        self.assertEqual((take / 'raw-recognition.txt').read_text(), 'my address.')
        self.assertEqual((take / 'transcript.txt').read_text(), 'First Street.')
        self.session.command('start')
        self.finish()
        self.assertEqual([call[0] for call in self.delivery.calls], ['First Street.', 'Second Street.'])

    def test_invalid_phrase_library_refuses_capture_without_allocating_a_take(self):
        self.path.write_text('private broken data')
        status = self.session.command('start')
        self.assertEqual(status['error'], 'phrases_unavailable')
        self.assertEqual(self.capture.starts, 0)
        self.assertEqual(list(self.session.recovery.iterdir()), [])
        self.assertNotIn('private', json.dumps(status))

    def test_explicit_raw_recovery_uses_current_phrases_without_paste_or_inference(self):
        take = self.session.recovery / ('a' * 32)
        take.mkdir()
        Capture().start(take / 'recording.wav')
        desktop.private_write(take / 'raw-recognition.txt', 'my address.\r\n')
        self.write('Recovered Street')
        self.session.recover_audio(take.name)
        self.session.wait()
        self.assertEqual((take / 'transcript.txt').read_bytes(), b'Recovered Street.\r\n')
        self.assertEqual((take / 'raw-recognition.txt').read_bytes(), b'my address.\r\n')
        self.assertEqual(self.engine.calls, 0)
        self.assertEqual(self.delivery.calls, [])


class PhrasePipelineTests(PhraseSessionFixture, unittest.TestCase):
    def test_phrase_expansions_are_not_rewritten_by_saved_spellings(self):
        dictionary = self.root / 'dictionary.json'
        dictionary.write_text('[{"heard":"First Street","written":"wrong"}]')
        self.session.dictionary = dictionary
        self.session.command('start')
        self.finish()
        self.assertEqual(self.delivery.calls[0][0], 'First Street.')

    def test_failed_expansion_preserves_raw_for_retry_without_new_inference(self):
        self.write('café' * 4000)
        self.engine.text = 'my address ' * 150
        self.session.command('start')
        self.finish()
        take = self.session.take
        self.assertEqual(self.session.error, 'transcription_failed')
        self.assertEqual((take / 'raw-recognition.txt').read_text(), self.engine.text)
        self.assertFalse((take / 'transcript.txt').exists())
        self.assertEqual(self.delivery.calls, [])
        self.write('small')
        self.session.recover_audio(take.name)
        self.session.wait()
        self.assertEqual(self.engine.calls, 1)
        self.assertTrue((take / 'transcript.txt').is_file())
        self.assertEqual(self.delivery.calls, [])

    def test_context_permission_defaults_off_and_snapshots_the_explicit_clipboard(self):
        self.write('{clipboard}')
        calls = []
        self.session.clipboard = lambda: calls.append('read') or 'copied {date}'
        self.assertEqual(self.session.command('start')['error'], 'phrase_context_unavailable')
        self.assertEqual(calls, [])
        self.assertEqual(self.capture.starts, 0)
        self.session.phrase_clipboard = True
        self.session.command('start')
        self.session.clipboard = lambda: self.fail('must not reread clipboard during recognition')
        self.finish()
        self.assertEqual(calls, ['read'])
        self.assertEqual(self.delivery.calls[0][0], 'copied {date}.')

    def test_cancel_during_phrase_matching_discards_only_the_new_take(self):
        import threading
        entered, release, cancelled = threading.Event(), threading.Event(), threading.Event()
        class Paused:
            def apply(self, text):
                entered.set()
                if not release.wait(3):
                    raise RuntimeError('Fixture deadline')
                return 'late'
        self.session.command('start')
        take = self.session.take
        self.session.phrase_rules = Paused()
        self.session.command('stop')
        self.assertTrue(entered.wait(1))
        def cancel():
            self.session.command('cancel')
            cancelled.set()
        thread = threading.Thread(target=cancel)
        thread.start()
        try:
            self.assertTrue(cancelled.wait(1))
            self.assertFalse(take.exists())
            self.assertEqual(self.delivery.calls, [])
        finally:
            release.set()
            thread.join(2)
            self.session.wait()
        self.assertFalse(thread.is_alive())
        self.assertFalse(take.exists())
        self.assertEqual(self.session.state, 'idle')

    def test_context_failure_is_reported_separately_from_a_bad_phrase_library(self):
        self.write('{clipboard}')
        self.session.phrase_clipboard = True
        def unavailable():
            raise FileNotFoundError('private helper path')
        self.session.clipboard = unavailable
        self.assertEqual(self.session.command('start')['error'], 'phrase_context_unavailable')
        self.assertEqual(self.capture.starts, 0)
        self.assertNotIn('private', json.dumps(self.session.status()))

    def test_relative_phrase_config_and_explicit_context_flag(self):
        from unittest.mock import patch
        config = self.root / 'linux.json'
        config.write_text(json.dumps({'engine_config': 'engine.json', 'phrases': 'phrases.json',
                                      'phrase_clipboard': True, 'notifications': False}))
        (self.root / 'engine.json').write_text('{"engines":{"speech":{}}}')
        def serve(_path, session, *_args, **_kwargs):
            self.assertEqual(session.phrases, self.path.resolve())
            self.assertTrue(session.phrase_clipboard)
            session.command('start')
            session.command('stop')
            session.wait()
            self.assertEqual((session.take / 'transcript.txt').read_text(), 'First Street.')
        argv = ['mouthtype-linux', '--config', str(config), '--runtime', str(self.root / 'runtime'),
                '--recovery', str(self.root / 'other-recovery'), 'serve']
        with patch('desktop.sys.argv', argv), patch('desktop.sys.platform', 'linux'), \
                patch('desktop.signal.signal'), patch('desktop.SpeechEngine', return_value=self.engine), \
                patch('desktop.PipeWireCapture', return_value=self.capture), \
                patch('desktop.HyprlandDelivery', return_value=self.delivery), patch('desktop.serve', serve):
            self.assertEqual(desktop.main(), 0)
        for value in ('', None, 1, 'bad\0path'):
            with self.subTest(path=value), self.assertRaises(ValueError):
                desktop.validate_config({'engine_config': 'engine.json', 'phrases': value})
        for value in (None, 1, 'true'):
            with self.subTest(flag=value), self.assertRaises(ValueError):
                desktop.validate_config({'engine_config': 'engine.json', 'phrase_clipboard': value})


if __name__ == '__main__':
    unittest.main()
