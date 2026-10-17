import json
from pathlib import Path
import tempfile
import unittest

import desktop
from test_desktop import Capture, Delivery, Engine


class CleanupSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.capture, self.engine, self.delivery = Capture(), Engine('hello comma world new paragraph see ./dusting'), Delivery()
        self.session = desktop.Session(self.capture, self.engine, self.delivery, self.root / 'recovery')

    def tearDown(self):
        self.session.close()
        self.temp.cleanup()

    def finish(self):
        self.session.command('stop')
        self.session.wait()

    def test_basic_cleanup_is_opt_in_and_snapshotted_per_take(self):
        self.session.command('start')
        self.finish()
        self.assertEqual(self.delivery.calls[0][0], self.engine.text)
        self.session.cleanup = 'basic'
        self.session.command('start')
        self.session.cleanup = 'off'
        self.finish()
        self.assertEqual(self.delivery.calls[1][0], 'Hello, world\n\nSee ./dusting')
        self.assertEqual((self.session.take / 'raw-recognition.txt').read_text(), self.engine.text)

    def test_basic_cleanup_precedes_literal_saved_phrase_output(self):
        phrases = self.root / 'phrases.json'
        phrases.write_text('[{"trigger":"my code","expansion":"  src/Main\\n    keep  these spaces  "}]')
        self.session.phrases = phrases
        self.session.cleanup = 'basic'
        self.engine.text = 'my code'
        self.session.command('start')
        self.finish()
        self.assertEqual(self.delivery.calls[0][0], '  src/Main\n    keep  these spaces  ')

    def test_invalid_cleanup_setting_is_rejected(self):
        for value in ('unknown', None, True, 0, {}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                desktop.validate_config({'engine_config': 'engine.json', 'cleanup': value})

    def test_explicit_raw_recovery_formats_without_another_inference_or_delivery(self):
        take = self.session.recovery / ('a' * 32)
        take.mkdir()
        Capture().start(take / 'recording.wav')
        desktop.private_write(take / 'raw-recognition.txt', self.engine.text)
        self.session.cleanup = 'basic'
        self.session.recover_audio(take.name)
        self.session.wait()
        self.assertEqual(self.engine.calls, 0)
        self.assertEqual(self.delivery.calls, [])
        self.assertEqual((take / 'raw-recognition.txt').read_text(), self.engine.text)
        self.assertEqual((take / 'transcript.txt').read_text(), 'Hello, world\n\nSee ./dusting')

    def test_cleanup_error_keeps_raw_text_and_audio_for_explicit_retry(self):
        self.session.cleanup = 'basic'
        self.engine.text = 'x' * (2 * 1024 * 1024 + 1)
        self.session.command('start')
        self.finish()
        take = self.session.take
        self.assertEqual(self.session.error, 'transcription_failed')
        self.assertTrue((take / 'recording.wav').exists())
        self.assertEqual((take / 'raw-recognition.txt').read_text(), self.engine.text)
        self.assertFalse((take / 'transcript.txt').exists())
        self.assertEqual(self.delivery.calls, [])

    def test_cancel_during_cleanup_cannot_write_or_deliver_late_text(self):
        import threading
        entered, release, cancelled = threading.Event(), threading.Event(), threading.Event()
        class Paused:
            def apply(self, text):
                entered.set()
                if not release.wait(3):
                    raise RuntimeError('Fixture deadline')
                return 'late result'
        self.session.cleanup = 'basic'
        self.session.command('start')
        self.session.cleanup_rules = Paused()
        self.session.command('stop')
        self.assertTrue(entered.wait(1))
        take = self.session.take
        def cancel():
            self.session.command('cancel')
            cancelled.set()
        thread = threading.Thread(target=cancel)
        thread.start()
        try:
            self.assertTrue(cancelled.wait(1), 'Cancellation must not wait for cleanup')
            self.assertFalse(take.exists())
        finally:
            release.set()
            thread.join(2)
            self.session.wait()
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.session.state, 'idle')
        self.assertFalse(take.exists())
        self.assertEqual(self.delivery.calls, [])

    def test_runtime_rejects_an_invalid_cleanup_mode_before_capture(self):
        self.session.cleanup = 'invalid'
        self.assertEqual(self.session.command('start')['error'], 'cleanup_unavailable')
        self.assertEqual(self.capture.starts, 0)
        self.assertEqual(list(self.session.recovery.iterdir()), [])

    def test_service_configuration_selects_basic_cleanup(self):
        from unittest.mock import patch
        config = self.root / 'linux.json'
        config.write_text(json.dumps({'engine_config': 'engine.json', 'cleanup': 'basic', 'notifications': False}))
        (self.root / 'engine.json').write_text('{"engines":{"speech":{}}}')
        def serve(_path, session, *_args, **_kwargs):
            self.assertEqual(session.cleanup, 'basic')
            session.command('start')
            session.command('stop')
            session.wait()
            self.assertEqual((session.take / 'transcript.txt').read_text(), 'Hello, world\n\nSee ./dusting')
        argv = ['mouthtype-linux', '--config', str(config), '--runtime', str(self.root / 'runtime'),
                '--recovery', str(self.root / 'other-recovery'), 'serve']
        with patch('desktop.sys.argv', argv), patch('desktop.sys.platform', 'linux'), \
                patch('desktop.signal.signal'), patch('desktop.SpeechEngine', return_value=self.engine), \
                patch('desktop.PipeWireCapture', return_value=self.capture), \
                patch('desktop.HyprlandDelivery', return_value=self.delivery), patch('desktop.serve', serve):
            self.assertEqual(desktop.main(), 0)
