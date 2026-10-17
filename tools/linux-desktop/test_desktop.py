import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
import wave

from desktop import Session


class Capture:
    def __init__(self):
        self.starts = 0
        self.stops = 0
        self.cancelled = 0
        self.alive = True
    def start(self, path):
        self.starts += 1
        self.path = path
        with wave.open(str(path), 'wb') as audio:
            audio.setparams((1, 2, 16000, 0, 'NONE', ''))
            audio.writeframes(b'\0\0' * 1600)
    def stop(self):
        self.stops += 1
    def cancel(self):
        self.cancelled += 1
    def running(self):
        return self.alive


class Engine:
    def __init__(self, text='Hello, 世界. café 👋'):
        self.text = text
        self.calls = 0
        self.gate = None
        self.entered = threading.Event()
    def transcribe(self, path, cancelled):
        self.calls += 1
        self.entered.set()
        if self.gate:
            while not self.gate.wait(.005):
                if cancelled.is_set():
                    raise RuntimeError('cancelled')
        return self.text
    def close(self):
        pass


class Delivery:
    def __init__(self):
        self.calls = []
        self.target = {'address': '0x123', 'class': 'editor', 'pid': 42}
    def snapshot(self):
        return self.target.copy()
    def submit(self, text, target):
        self.calls.append((text, target))
        return 'unknown'


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.capture, self.engine, self.delivery = Capture(), Engine(), Delivery()
        self.now = [0.0]
        self.session = Session(self.capture, self.engine, self.delivery, Path(self.temp.name),
                               maximum_seconds=5, clock=lambda: self.now[0])
    def tearDown(self):
        self.session.close()
        self.temp.cleanup()
    def finish(self):
        self.session.command('stop')
        self.session.wait()
    def test_hold_release_transcribes_and_submits_once(self):
        self.session.command('start')
        self.assertEqual(self.session.state, 'recording')
        self.session.command('start')
        self.finish()
        self.session.command('stop')
        self.assertEqual(self.capture.starts, 1)
        self.assertEqual(self.engine.calls, 1)
        self.assertEqual(len(self.delivery.calls), 1)
        status = self.session.command('status')
        self.assertEqual(status['delivery'], 'unknown')
        self.assertNotIn(self.engine.text, json.dumps(status))
        saved = list(Path(self.temp.name).glob('*/transcript.txt'))
        self.assertEqual(saved[0].read_text(), self.engine.text)
        self.assertEqual(saved[0].stat().st_mode & 0o777, 0o600)
    def test_toggle_starts_and_stops(self):
        self.session.command('toggle')
        self.assertEqual(self.capture.starts, 1)
        self.session.command('toggle')
        self.session.wait()
        self.assertEqual(self.engine.calls, 1)
    def test_cancel_recording_never_transcribes(self):
        self.session.command('start')
        self.session.command('cancel')
        self.session.command('stop')
        self.assertEqual(self.capture.cancelled, 1)
        self.assertEqual(self.engine.calls, 0)
        self.assertFalse(list(Path(self.temp.name).glob('*/recording.wav')))
    def test_cancel_during_inference_cannot_deliver_late_text(self):
        self.engine.gate = threading.Event()
        self.session.command('start')
        self.session.command('stop')
        self.assertTrue(self.engine.entered.wait(1))
        self.session.command('cancel')
        self.engine.gate.set()
        self.session.wait()
        self.assertEqual(self.delivery.calls, [])
        self.assertEqual(self.session.state, 'idle')
    def test_focus_changed_while_speaking_preserves_result_without_delivery(self):
        self.session.command('start')
        self.delivery.target['address'] = '0x999'
        self.finish()
        self.assertEqual(self.delivery.calls, [])
        self.assertEqual(self.session.command('status')['delivery'], 'target_changed')
        self.assertTrue(list(Path(self.temp.name).glob('*/transcript.txt')))
    def test_recording_cap_cancels_instead_of_inserting_partial_take(self):
        self.session.command('start')
        self.now[0] = 5
        self.session.tick()
        self.assertEqual(self.capture.cancelled, 1)
        self.assertEqual(self.session.command('status')['error'], 'recording_limit')
        self.assertEqual(self.delivery.calls, [])
        self.assertEqual(self.engine.calls, 0)
    def test_device_loss_preserves_audio_without_transcribing(self):
        self.session.command('start')
        self.capture.alive = False
        self.session.tick()
        self.assertEqual(self.session.command('status')['error'], 'capture_interrupted')
        self.assertTrue(list(Path(self.temp.name).glob('*/recording.wav')))
        self.assertEqual(self.engine.calls, 0)
    def test_engine_failure_preserves_audio_and_allows_explicit_new_take(self):
        original = self.engine.transcribe
        self.engine.transcribe = lambda *_: (_ for _ in ()).throw(ValueError('private detail'))
        self.session.command('start')
        self.finish()
        self.assertEqual(self.session.command('status')['error'], 'transcription_failed')
        self.assertNotIn('private detail', json.dumps(self.session.command('status')))
        self.engine.transcribe = original
        self.session.command('start')
        self.finish()
        self.assertEqual(len(self.delivery.calls), 1)
    def test_busy_start_does_not_open_second_capture(self):
        self.engine.gate = threading.Event()
        self.session.command('start')
        self.session.command('stop')
        self.assertTrue(self.engine.entered.wait(1))
        self.session.command('start')
        self.assertEqual(self.capture.starts, 1)
        self.engine.gate.set()
        self.session.wait()

class AdapterTests(unittest.TestCase):
    def test_unicode_delivery_is_one_stdin_submission_and_stays_unverified(self):
        from desktop import HyprlandDelivery
        calls = []
        target = {'address': '0x123', 'class': 'editor', 'pid': 42}
        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[-1] == 'locked':
                return type('Result', (), {'stdout': json.dumps({'locked': False})})()
            if argv[-1] == 'activewindow':
                return type('Result', (), {'stdout': json.dumps({**target, 'title': 'private'})})()
            return type('Result', (), {'returncode': 0})()
        delivery = HyprlandDelivery({'mode': 'type', 'allowed_classes': ['editor'],
                                    'allow_unknown_secure_field': True}, run=run)
        self.assertEqual(delivery.snapshot(), target)
        self.assertEqual(delivery.submit('Émilie 世界 👋 --hello', target), 'unknown')
        submissions = [(a, k) for a, k in calls if a[0] == 'wtype']
        self.assertEqual(len(submissions), 1)
        self.assertEqual(submissions[0][0], ['wtype', '-'])
        self.assertEqual(submissions[0][1]['input'], 'Émilie 世界 👋 --hello'.encode())
        self.assertNotIn('private', json.dumps(delivery.snapshot()))
    def test_default_and_unknown_secure_field_are_not_automatic_delivery(self):
        from desktop import HyprlandDelivery
        for config in ({}, {'mode': 'type', 'allowed_classes': ['editor']}):
            delivery = HyprlandDelivery(config, run=lambda *_a, **_k: self.fail('No desktop action permitted'))
            self.assertEqual(delivery.submit('Hello', {}), 'recover_only')
    def test_return_tab_escape_and_controls_are_never_synthetic_keys(self):
        from desktop import HyprlandDelivery
        delivery = HyprlandDelivery({'mode': 'type', 'allowed_classes': ['editor'],
                                    'allow_unknown_secure_field': True},
                                   run=lambda *_a, **_k: self.fail('Control text must not reach desktop'))
        for text in ['one\ntwo', 'one\ttwo', '\x1b', '\0', 'hello\r', '\x7f']:
            self.assertEqual(delivery.submit(text, {'class': 'editor'}), 'unsupported_text')
    def test_changed_or_unknown_target_never_gets_text(self):
        from desktop import HyprlandDelivery
        delivery = HyprlandDelivery({'mode': 'type', 'allowed_classes': ['editor'],
                                    'allow_unknown_secure_field': True})
        delivery.snapshot = lambda: None
        self.assertEqual(delivery.submit('Hello', {'class': 'editor'}), 'target_changed')
    def test_timeout_after_partial_typing_does_not_retry(self):
        from desktop import HyprlandDelivery
        import subprocess
        calls = []
        target = {'class': 'editor'}
        def run(*args, **kwargs):
            calls.append(args)
            raise subprocess.TimeoutExpired(args[0], 2)
        delivery = HyprlandDelivery({'mode': 'type', 'allowed_classes': ['editor'],
                                    'allow_unknown_secure_field': True}, run=run)
        delivery.snapshot = lambda: target
        self.assertEqual(delivery.submit('Hello', target), 'unknown')
        self.assertEqual(len(calls), 1)
    def test_capture_refuses_invalid_audio_after_stop(self):
        from desktop import PipeWireCapture
        capture = PipeWireCapture()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'bad.wav'
            path.write_bytes(b'bad')
            capture.path = path
            capture.process = None
            with self.assertRaises(ValueError):
                capture.stop()
    def test_recording_command_is_fixed_and_device_is_one_argument(self):
        from desktop import PipeWireCapture
        capture = PipeWireCapture(target='usb mic; not a command')
        self.assertEqual(capture.argv(Path('/private/take.wav')),
            ['pw-record', '--rate=16000', '--channels=1', '--format=s16',
             '--target=usb mic; not a command', '/private/take.wav'])

class RuntimeTests(unittest.TestCase):
    def test_resident_engine_handles_two_takes_without_reloading(self):
        from desktop import SpeechEngine
        with tempfile.TemporaryDirectory() as temp:
            worker = Path(temp) / 'worker.py'
            worker.write_text('''import json,sys
json.loads(sys.stdin.readline())
print(json.dumps({'event':'ready'}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 print(json.dumps({'id':r['id'],'text':'Hello, 世界'}),flush=True)
''')
            engine = SpeechEngine({'artifacts': {}}, worker=worker)
            try:
                first = engine.transcribe(Path('/not-used.wav'), threading.Event())
                self.assertEqual(first, 'Hello, 世界')
                pid = engine.worker.process.pid
                self.assertEqual(engine.transcribe(Path('/another.wav'), threading.Event()), first)
                self.assertEqual(engine.worker.process.pid, pid)
            finally:
                engine.close()
    def test_engine_deadline_reaps_worker_and_next_take_reloads(self):
        from desktop import SpeechEngine
        with tempfile.TemporaryDirectory() as temp:
            worker = Path(temp) / 'worker.py'
            worker.write_text('''import json,sys,time
json.loads(sys.stdin.readline())
print(json.dumps({'event':'ready'}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 time.sleep(10)
''')
            engine = SpeechEngine({'artifacts': {}}, worker=worker, request_seconds=.05)
            with self.assertRaises(RuntimeError):
                engine.transcribe(Path('/not-used.wav'), threading.Event())
            self.assertIsNone(engine.worker)
            engine.close()
    def test_configuration_rejects_unbounded_or_ambiguous_delivery(self):
        from desktop import validate_config
        for change in ({'maximum_recording_seconds': float('nan')},
                       {'maximum_recording_seconds': 121},
                       {'request_seconds': 0}, {'delivery': {'mode': 'clipboard'}},
                       {'delivery': {'mode': 'type', 'allowed_classes': ['*']}},
                       {'delivery': {'mode': 'type', 'allowed_classes': []}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_config({'engine_config': '/local/engines.json', **change})
    def test_unix_service_status_repeated_release_and_shutdown(self):
        from desktop import serve, request
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'session.sock'
            session = Session(Capture(), Engine(), Delivery(), Path(temp) / 'recovery')
            stopped = threading.Event()
            thread = threading.Thread(target=serve, args=(path, session, stopped),
                                      kwargs={'lifetime_seconds': 2})
            thread.start()
            try:
                deadline = time.monotonic() + 1
                initial = None
                while time.monotonic() < deadline:
                    try:
                        initial = request(path, 'status')
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        time.sleep(.005)
                self.assertEqual(initial['state'], 'idle')
                self.assertEqual(request(path, 'start')['state'], 'recording')
                request(path, 'stop')
                session.wait()
                request(path, 'stop')
                self.assertEqual(session.capture.starts, 1)
                self.assertEqual(session.engine.calls, 1)
                self.assertEqual(len(session.delivery.calls), 1)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            finally:
                stopped.set()
                thread.join(3)
                session.close()
            self.assertFalse(thread.is_alive())
            self.assertFalse(path.exists())

class RecoveryTests(unittest.TestCase):
    def test_recovery_is_explicit_read_only_and_never_delivers(self):
        from desktop import recovery_result, recovery_list
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            take = root / ('a' * 32)
            take.mkdir()
            (take / 'transcript.txt').write_text('Private 世界')
            listing = recovery_list(root)
            self.assertEqual(listing, [{'id': 'a' * 32, 'transcript': True, 'audio': False}])
            self.assertNotIn('Private', json.dumps(listing))
            self.assertEqual(recovery_result(root, 'a' * 32), 'Private 世界')
            self.assertEqual(recovery_result(root, 'a' * 32), 'Private 世界')
            for invalid in ('../other', '', 'A' * 32):
                with self.assertRaises(ValueError):
                    recovery_result(root, invalid)
    def test_full_recovery_store_never_silently_deletes_old_takes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for number in range(50):
                (root / str(number)).mkdir()
            session = Session(Capture(), Engine(), Delivery(), root)
            try:
                self.assertEqual(session.command('start')['error'], 'recovery_full')
                self.assertEqual(session.capture.starts, 0)
                self.assertEqual(len(list(root.iterdir())), 50)
            finally:
                session.close()
    def test_cancelled_inference_must_finish_before_another_capture_starts(self):
        with tempfile.TemporaryDirectory() as temp:
            engine = Engine()
            gate = threading.Event()
            entered = threading.Event()
            def blocked(_path, _cancelled):
                entered.set()
                gate.wait(1)
                return 'late'
            engine.transcribe = blocked
            session = Session(Capture(), engine, Delivery(), Path(temp))
            try:
                session.command('start')
                session.command('stop')
                self.assertTrue(entered.wait(1))
                session.command('cancel')
                session.command('start')
                self.assertEqual(session.capture.starts, 1)
                gate.set()
                session.wait()
                self.assertEqual(session.state, 'idle')
            finally:
                gate.set()
                session.close()

class RecoveryAudioTests(unittest.TestCase):
    def test_explicit_audio_recovery_transcribes_but_never_submits(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            take = root / ('b' * 32)
            take.mkdir()
            Capture().start(take / 'recording.wav')
            delivery = Delivery()
            session = Session(Capture(), Engine(), delivery, root)
            try:
                session.recover_audio('b' * 32)
                session.wait()
                self.assertTrue((take / 'transcript.txt').is_file())
                self.assertEqual((take / 'transcript.txt').read_text(), session.engine.text)
                self.assertEqual(delivery.calls, [])
                self.assertEqual(session.command('status')['delivery'], 'recover_only')
                session.recover_audio('b' * 32)
                self.assertEqual(session.engine.calls, 1)
            finally:
                session.close()

class ProcessCaptureTests(unittest.TestCase):
    def test_real_capture_process_finalizes_private_wav_and_is_reaped(self):
        from desktop import PipeWireCapture
        import sys
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake = root / 'record.py'
            ready = root / 'ready'
            fake.write_text('''import signal,sys,time,wave
from pathlib import Path
path=Path(sys.argv[1])
audio=wave.open(str(path),'wb')
audio.setparams((1,2,16000,0,'NONE',''))
audio.writeframes(b'\\0\\0'*1600)
def stop(*_):
 audio.close()
 sys.exit(0)
signal.signal(signal.SIGINT,stop)
Path(sys.argv[2]).touch()
while True: time.sleep(.01)
''')
            capture = PipeWireCapture()
            capture.argv = lambda path: [sys.executable, str(fake), str(path), str(ready)]
            try:
                capture.start(root / 'recording.wav')
                process = capture.process
                deadline = time.monotonic() + 1
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
                self.assertTrue(ready.exists())
                self.assertTrue(capture.running())
                capture.stop()
                self.assertEqual(process.returncode, 0)
                self.assertIsNone(capture.process)
                self.assertEqual((root / 'recording.wav').stat().st_mode & 0o777, 0o600)
            finally:
                capture.cancel()
    def test_request_read_is_bounded_and_rejects_second_command(self):
        from desktop import read_message
        import socket
        for raw in (b'{}\n{}\n', b'x' * 4097):
            left, right = socket.socketpair()
            try:
                left.settimeout(.1)
                right.sendall(raw)
                with self.assertRaises(ValueError):
                    read_message(left)
            finally:
                left.close()
                right.close()

class PrivacyTests(unittest.TestCase):
    def test_existing_shared_recovery_directory_is_not_silently_used(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'recovery'
            root.mkdir(mode=0o755)
            root.chmod(0o755)
            with self.assertRaises(ValueError):
                Session(Capture(), Engine(), Delivery(), root)
    def test_idle_cancel_does_not_delete_completed_take_audio(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            session = Session(Capture(), Engine(), Delivery(), root)
            try:
                session.command('start')
                session.command('stop')
                session.wait()
                before = list(root.glob('*/recording.wav'))
                self.assertEqual(len(before), 1)
                session.command('cancel')
                self.assertTrue(before[0].is_file())
            finally:
                session.close()

class EngineConfigTests(unittest.TestCase):
    def test_malformed_artifact_config_fails_before_recording(self):
        from desktop import SpeechEngine
        for settings in ([], {'artifacts': []}, {'artifacts': {'model': 'wrong'}},
                         {'artifacts': {'model': {'path': '/local/model', 'sha256': 'wrong'}}}):
            with self.subTest(settings=settings), self.assertRaises(ValueError):
                SpeechEngine(settings)

class ReviewCancellationTests(unittest.TestCase):
    def test_cancel_audio_recovery_preserves_original_audio_and_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            take = root / ('a' * 32)
            take.mkdir()
            Capture().start(take / 'recording.wav')
            original = (take / 'recording.wav').read_bytes()
            engine = Engine()
            engine.gate = threading.Event()
            session = Session(Capture(), engine, Delivery(), root)
            try:
                session.recover_audio('a' * 32)
                self.assertTrue(engine.entered.wait(1))
                session.command('cancel')
                session.wait()
                self.assertTrue(take.is_dir())
                self.assertTrue((take / 'recording.wav').is_file())
                self.assertEqual((take / 'recording.wav').read_bytes(), original)
                self.assertEqual(session.delivery.calls, [])
            finally:
                engine.gate.set()
                session.close()
    def test_repeated_cancel_stays_busy_until_worker_quiesces(self):
        with tempfile.TemporaryDirectory() as temp:
            engine = Engine()
            entered, gate = threading.Event(), threading.Event()
            def blocked(_path, _cancelled):
                entered.set()
                gate.wait(2)
                return 'discarded'
            engine.transcribe = blocked
            session = Session(Capture(), engine, Delivery(), Path(temp))
            try:
                session.command('start')
                session.command('stop')
                self.assertTrue(entered.wait(1))
                self.assertEqual(session.command('cancel')['state'], 'cancelling')
                self.assertEqual(session.command('cancel')['state'], 'cancelling')
                session.command('start')
                self.assertEqual(session.capture.starts, 1)
                gate.set()
                session.wait()
                self.assertEqual(session.state, 'idle')
                self.assertEqual(session.delivery.calls, [])
            finally:
                gate.set()
                session.close()

class AdmissionTests(unittest.TestCase):
    def test_expired_start_cannot_open_microphone_after_slow_target_lookup(self):
        with tempfile.TemporaryDirectory() as temp:
            delivery = Delivery()
            original = delivery.snapshot
            def slow():
                time.sleep(.04)
                return original()
            delivery.snapshot = slow
            session = Session(Capture(), Engine(), delivery, Path(temp))
            try:
                result = session.command('start', admit_before=time.monotonic() + .01)
                self.assertEqual(session.capture.starts, 0)
                self.assertEqual(result['state'], 'idle')
                self.assertEqual(result['error'], 'command_expired')
                self.assertEqual(list(Path(temp).iterdir()), [])
            finally:
                session.close()
    def test_expired_queued_toggle_does_not_start_recording(self):
        with tempfile.TemporaryDirectory() as temp:
            session = Session(Capture(), Engine(), Delivery(), Path(temp))
            try:
                result = session.command('toggle', admit_before=time.monotonic() - 1)
                self.assertEqual(session.capture.starts, 0)
                self.assertEqual(result['error'], 'command_expired')
            finally:
                session.close()

class CaptureExitContractTests(unittest.TestCase):
    def check_helper(self, natural):
        import sys
        from desktop import PipeWireCapture
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / 'record.py'
            ready = root / 'ready'
            script.write_text("""import signal,sys,time,wave
from pathlib import Path
with wave.open(sys.argv[1],'wb') as audio:
 audio.setparams((1,2,16000,0,'NONE',''))
 audio.writeframes(b'\\0\\0'*1600)
signal.signal(signal.SIGINT,lambda *_:sys.exit(1))
Path(sys.argv[2]).touch()
if sys.argv[3]=='natural':sys.exit(1)
while True:time.sleep(.01)
""")
            capture = PipeWireCapture()
            capture.argv = lambda path: [sys.executable, str(script), str(path), str(ready), 'natural' if natural else 'controlled']
            try:
                capture.start(root / 'take.wav')
                process = capture.process
                deadline = time.monotonic() + 1
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
                self.assertTrue(ready.exists())
                if natural:
                    process.wait(timeout=1)
                    with self.assertRaises(ValueError):
                        capture.stop()
                else:
                    finalized = True
                    try:
                        capture.stop()
                    except ValueError:
                        finalized = False
                    self.assertTrue(finalized, 'pw-record controlled SIGINT exits1 after finalizing WAV')
                    self.assertEqual(process.returncode, 1)
            finally:
                capture.cancel()
    def test_controlled_sigint_exit_one_still_requires_valid_pcm(self):
        self.check_helper(False)
    def test_natural_exit_one_is_capture_interruption_even_with_valid_pcm(self):
        self.check_helper(True)

if __name__ == '__main__':
    unittest.main()
