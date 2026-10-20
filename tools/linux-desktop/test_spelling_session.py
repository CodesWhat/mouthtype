import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import desktop
from test_desktop import Capture, Delivery, Engine


class SpellingSessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.dictionary = self.root / 'dictionary.json'
        self.write_rules('API')
        self.capture, self.engine, self.delivery = Capture(), Engine('api café'), Delivery()
        self.session = desktop.Session(self.capture, self.engine, self.delivery,
                                       self.root / 'recovery')
        self.session.dictionary = self.dictionary

    def tearDown(self):
        self.session.close()
        self.temp.cleanup()

    def write_rules(self, written):
        self.dictionary.write_text(json.dumps([{'heard': 'api', 'written': written}]))

    def finish(self):
        self.session.command('stop')
        self.session.wait()

    def test_invalid_dictionary_refuses_capture_without_allocating_take(self):
        self.dictionary.write_text('broken private data')
        status = self.session.command('start')
        self.assertEqual(status['error'], 'dictionary_unavailable')
        self.assertEqual(self.capture.starts, 0)
        self.assertEqual(list(self.session.recovery.iterdir()), [])
        self.assertNotIn('private', json.dumps(status))
        self.write_rules('API')
        self.assertEqual(self.session.command('start')['state'], 'recording')

    def test_dictionary_load_that_exceeds_admission_never_starts_late_capture(self):
        from spellings import Spellings
        with patch('desktop.time.monotonic', side_effect=[10.0, 12.0]), \
                patch('desktop.load_spellings', return_value=Spellings([])):
            status = self.session.command('start', admit_before=11.0)
        self.assertEqual(status['error'], 'command_expired')
        self.assertEqual(self.capture.starts, 0)
        self.assertEqual(list(self.session.recovery.iterdir()), [])

    def test_raw_recovery_retains_original_crlf_bytes(self):
        self.engine.text = 'api\r\nnext'
        self.session.command('start')
        self.finish()
        take = self.session.take
        self.assertEqual((take / 'raw-recognition.txt').read_bytes(), b'api\r\nnext')
        self.assertEqual(desktop.recovery_result(self.session.recovery, take.name, raw=True), 'api\r\nnext')

    def test_failed_private_write_removes_only_new_partial_file(self):
        path = self.root / 'result.txt'
        with self.assertRaises(UnicodeEncodeError):
            desktop.private_write(path, '\ud800')
        self.assertFalse(path.exists())
        path.write_text('existing result')
        with self.assertRaises(FileExistsError):
            desktop.private_write(path, 'replacement')
        self.assertEqual(path.read_text(), 'existing result')

    def test_take_metadata_write_failure_leaves_no_take_directory(self):
        with patch.object(desktop, 'private_write', side_effect=OSError('disk full')):
            status = self.session.command('start')
        self.assertEqual(status['error'], 'capture_unavailable')
        self.assertEqual(list(self.session.recovery.iterdir()), [])
        self.assertEqual(self.session.take_count(), 0)

    def test_forget_removes_take_json_with_the_take(self):
        self.session.command('start')
        self.finish()
        take = self.session.take
        self.assertTrue((take / 'take.json').exists())
        argv = [sys.executable, str(Path(desktop.__file__)), '--recovery', str(self.session.recovery),
                '--runtime', str(self.root / 'runtime')]
        result = subprocess.run(argv + ['forget', take.name], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(take.exists())

    def test_relative_dictionary_config_is_resolved_beside_client_config(self):
        config = self.root / 'linux.json'
        config.write_text(json.dumps({'engine_config': 'engine.json', 'dictionary': 'dictionary.json',
                                      'notifications': False}))
        (self.root / 'engine.json').write_text('{"engines":{"speech":{}}}')
        def serve(path, session, *_a, **_kw):
            self.assertEqual(session.dictionary, self.dictionary.resolve())
            self.assertEqual(session.command('start')['state'], 'recording')
            session.command('stop')
            session.wait()
            self.assertEqual((session.take / 'transcript.txt').read_text(), 'API café')
        argv = ['mouthtype-linux', '--config', str(config), '--runtime', str(self.root / 'runtime'),
                '--recovery', str(self.root / 'other-recovery'), '--imports', str(self.root / 'other-imports'), 'serve']
        with patch('desktop.sys.argv', argv), patch('desktop.sys.platform', 'linux'), \
                patch('desktop.signal.signal'), patch('desktop.SpeechEngine', return_value=self.engine), \
                patch('desktop.PipeWireCapture', return_value=self.capture), \
                patch('desktop.HyprlandDelivery', return_value=self.delivery), patch('desktop.serve', serve):
            self.assertEqual(desktop.main(), 0)
        for value in ('', None, 1, 'bad\0path'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                desktop.validate_config({'engine_config': 'engine.json', 'dictionary': value})

    def test_take_uses_start_snapshot_and_delivers_final_with_raw_preserved(self):
        self.session.command('start')
        self.write_rules('Changed')
        self.finish()
        take = self.session.take
        self.assertEqual(self.delivery.calls[0][0], 'API café')
        self.assertEqual((take / 'raw-recognition.txt').read_text(), 'api café')
        self.assertEqual((take / 'transcript.txt').read_text(), 'API café')
        self.assertEqual((take / 'raw-recognition.txt').stat().st_mode & 0o777, 0o600)
        self.session.command('start')
        self.finish()
        self.assertEqual(self.delivery.calls[1][0], 'Changed café')

    def test_failed_final_save_reuses_preserved_raw_without_second_inference(self):
        original = desktop.private_write
        def fail_final(path, text):
            if path.name == 'transcript.txt':
                raise OSError('full')
            original(path, text)
        self.session.command('start')
        with patch('desktop.private_write', fail_final):
            self.finish()
        take = self.session.take
        self.assertEqual((take / 'raw-recognition.txt').read_text(), 'api café')
        self.assertFalse((take / 'transcript.txt').exists())
        self.assertEqual(self.delivery.calls, [])
        self.write_rules('Recovered')
        self.session.recover_audio(take.name)
        self.session.wait()
        self.assertEqual(self.engine.calls, 1)
        self.assertEqual((take / 'raw-recognition.txt').read_text(), 'api café')
        self.assertEqual((take / 'transcript.txt').read_text(), 'Recovered café')
        self.assertEqual(self.delivery.calls, [])

    def test_cancel_new_inference_creates_neither_raw_nor_final(self):
        self.engine.gate = threading.Event()
        self.session.command('start')
        self.session.command('stop')
        self.assertTrue(self.engine.entered.wait(1))
        take = self.session.take
        self.session.command('cancel')
        self.engine.gate.set()
        self.session.wait()
        self.assertFalse(take.exists())
        self.assertEqual(self.delivery.calls, [])

    def test_cancel_during_matching_prevents_late_files_or_delivery(self):
        class PausedMatch:
            def __init__(self):
                self.entered, self.release = threading.Event(), threading.Event()
            def apply(self, text):
                self.entered.set()
                if not self.release.wait(3):
                    raise RuntimeError('Matcher fixture deadline')
                return 'API café'
        matcher = PausedMatch()
        completed = threading.Event()
        def cancel():
            self.session.command('cancel')
            completed.set()
        self.session.command('start')
        take = self.session.take
        self.session.spellings = matcher
        self.session.command('stop')
        self.assertTrue(matcher.entered.wait(1))
        thread = threading.Thread(target=cancel)
        thread.start()
        try:
            self.assertTrue(completed.wait(1), 'Cancellation must not wait for matching')
            self.assertEqual(self.session.state, 'cancelling')
            self.assertFalse(take.exists())
            self.assertEqual(self.delivery.calls, [])
        finally:
            matcher.release.set()
            thread.join(2)
            self.session.wait()
        self.assertFalse(thread.is_alive())
        self.assertEqual(self.session.state, 'idle')
        self.assertFalse(take.exists())
        self.assertEqual(self.delivery.calls, [])

    def test_recovery_cancel_preserves_old_audio_and_raw(self):
        take = self.session.recovery / ('a' * 32)
        take.mkdir()
        Capture().start(take / 'recording.wav')
        # Cancel while the recovered audio is transcribing, before any raw file is created.
        self.engine.gate = threading.Event()
        self.session.recover_audio(take.name)
        self.assertTrue(self.engine.entered.wait(1))
        self.session.command('cancel')
        self.engine.gate.set()
        self.session.wait()
        self.assertTrue((take / 'recording.wav').exists())
        self.assertFalse((take / 'raw-recognition.txt').exists())
        desktop.private_write(take / 'raw-recognition.txt', 'existing api')
        # Existing raw data and the WAV are never disposable on a recovered take.
        with self.session.lock:
            self.session.recover_audio(take.name)
            self.session.command('cancel')
        self.session.wait()
        self.assertEqual((take / 'raw-recognition.txt').read_text(), 'existing api')
        self.assertTrue((take / 'recording.wav').exists())
        self.assertEqual(self.delivery.calls, [])

    def test_cli_raw_recovery_and_forget_preserve_legacy_results(self):
        self.session.command('start')
        self.finish()
        take = self.session.take
        argv = [sys.executable, str(Path(desktop.__file__)), '--recovery', str(self.session.recovery),
                '--runtime', str(self.root / 'runtime')]
        result = subprocess.run(argv + ['recover', take.name, '--raw'], capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'api café')
        result = subprocess.run(argv + ['forget', take.name], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(take.exists())
        legacy = self.session.recovery / ('b' * 32)
        legacy.mkdir()
        desktop.private_write(legacy / 'transcript.txt', 'old result')
        self.assertEqual(desktop.recovery_result(self.session.recovery, legacy.name), 'old result')
        result = subprocess.run(argv + ['recover', legacy.name, '--raw'], capture_output=True,
                                text=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, '')
        self.assertEqual((legacy / 'transcript.txt').read_text(), 'old result')


if __name__ == '__main__':
    unittest.main()
