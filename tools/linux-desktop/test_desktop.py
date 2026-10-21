import os
import json
import socket
import subprocess
import sys
from pathlib import Path
import tempfile
import threading
import time
import unittest
import unittest.mock
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
    def test_repeated_capture_start_failure_does_not_fill_recovery_store(self):
        root = Path(self.temp.name)
        existing = root / ('a' * 32)
        existing.mkdir()
        (existing / 'recording.wav').write_bytes(b'previous saved audio')
        def unavailable(path):
            path.touch()
            raise FileNotFoundError('pw-record missing')
        self.capture.start = unavailable
        for _ in range(55):
            status = self.session.command('start')
            self.assertEqual(status['error'], 'capture_unavailable')
            self.assertIsNone(status['recovery'])
        self.assertEqual(list(root.iterdir()), [existing])
        self.assertEqual((existing / 'recording.wav').read_bytes(), b'previous saved audio')

    def test_failed_start_preserves_any_nonempty_new_recording(self):
        def interrupted(path):
            path.write_bytes(b'partial audio')
            raise OSError('capture interrupted')
        self.capture.start = interrupted
        status = self.session.command('start')
        self.assertEqual(status['error'], 'capture_unavailable')
        self.assertIsNotNone(status['recovery'])
        self.assertEqual((self.session.take / 'recording.wav').read_bytes(), b'partial audio')

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
                       {'request_seconds': 0}, {'notifications': 'yes'}, {'delivery': {'mode': 'clipboard'}},
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

    def test_second_serve_does_not_run_startup_maintenance_without_the_runtime_lock(self):
        import fcntl
        from desktop import serve
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'session.sock'
            session = Session(Capture(), Engine(), Delivery(), Path(temp) / 'recovery')
            ran = []
            with open(str(path) + '.lock', 'a') as owner:
                fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaises(OSError):
                    serve(path, session, threading.Event(), lifetime_seconds=1, startup=lambda: ran.append(1))
            self.assertEqual(ran, [])
            stopped = threading.Event()
            stopped.set()
            serve(path, session, stopped, lifetime_seconds=1, startup=lambda: ran.append(1))
            self.assertEqual(ran, [1])
            session.close()

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
            session = Session(Capture(), Engine(), Delivery(), root, maximum_takes=50)
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

class FeedbackTests(unittest.TestCase):
    def test_hotkey_state_transitions_have_coarse_feedback_without_transcript(self):
        class Feedback:
            status = 'submitted_unknown'
            def __init__(self): self.events = []
            def notify(self, state): self.events.append(state)
        with tempfile.TemporaryDirectory() as temp:
            feedback = Feedback()
            session = Session(Capture(), Engine(), Delivery(), Path(temp), feedback=feedback)
            try:
                session.command('start')
                session.command('start')
                session.command('stop')
                session.wait()
                self.assertEqual(feedback.events, ['recording', 'transcribing', 'delivered'])
                self.assertNotIn(session.engine.text, json.dumps(feedback.events))
                self.assertEqual(session.command('status')['feedback'], 'submitted_unknown')
            finally:
                session.close()
    def test_notification_failure_does_not_break_recording_or_delivery(self):
        class Feedback:
            status = 'unavailable'
            def notify(self, state): raise OSError('helper unavailable')
        with tempfile.TemporaryDirectory() as temp:
            session = Session(Capture(), Engine(), Delivery(), Path(temp), feedback=Feedback())
            try:
                session.command('start')
                self.assertEqual(session.state, 'recording')
                session.command('stop')
                session.wait()
                self.assertEqual(len(session.delivery.calls), 1)
            finally:
                session.close()
    def test_fake_notification_helper_replaces_id_and_uses_only_static_state(self):
        import sys
        from desktop import Notifications
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / 'notify.py'
            record = root / 'arguments.jsonl'
            script.write_text('import json,sys\nfrom pathlib import Path\nwith Path(sys.argv[1]).open("a") as f:f.write(json.dumps(sys.argv[2:])+"\\n")\nprint(17)\n')
            helper = Notifications(command=[sys.executable, str(script), str(record)])
            self.assertTrue(helper.notify('recording'))
            self.assertTrue(helper.notify('saved'))
            lines = [json.loads(line) for line in record.read_text().splitlines()]
            self.assertNotIn('--replace-id=17', lines[0])
            self.assertIn('--replace-id=17', lines[1])
            self.assertIn('Mouthtype is recording', lines[0])
            self.assertEqual(helper.status, 'submitted_unknown')
    def test_missing_or_hung_notification_helper_is_bounded_and_nonfatal(self):
        import sys
        from desktop import Notifications
        for command in (['/missing/notify-send'], [sys.executable, '-c', 'import time;time.sleep(5)']):
            helper = Notifications(command=command)
            started = time.monotonic()
            self.assertFalse(helper.notify('recording'))
            self.assertLess(time.monotonic()-started, 1)
            self.assertEqual(helper.status, 'unavailable')

class ShutdownFeedbackTests(unittest.TestCase):
    def test_shutdown_replaces_active_recording_cue_with_cancelled_state(self):
        class Feedback:
            status = 'submitted_unknown'
            def __init__(self):self.events=[]
            def notify(self,state):self.events.append(state)
        with tempfile.TemporaryDirectory() as temp:
            feedback=Feedback()
            session=Session(Capture(),Engine(),Delivery(),Path(temp),feedback=feedback)
            session.command('start')
            session.close()
            self.assertEqual(feedback.events,['recording','cancelled'])

if __name__ == '__main__':
    unittest.main()


class PasteDeliveryTests(unittest.TestCase):
    def make(self, config, clipboard='earlier text', terminal=False, hyprland=None):
        from desktop import HyprlandDelivery
        calls = []
        target = {'address': '0x123', 'class': 'kitty' if terminal else 'editor', 'pid': 42}
        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[-1] == 'locked':
                return type('Result', (), {'stdout': json.dumps({'locked': False})})()
            if argv[-1] == 'activewindow':
                return type('Result', (), {'stdout': json.dumps({**target, 'title': 'private'})})()
            return type('Result', (), {'returncode': 0})()
        delivery = HyprlandDelivery({'mode': 'paste', 'allow_unknown_secure_field': True, **config}, run=run)
        delivery.settle_seconds = 0
        state = {'copied': None}
        def read():
            if state['copied'] is not None:
                return state['copied']
            if isinstance(clipboard, Exception):
                raise clipboard
            return clipboard
        delivery.clipboard = read
        original_run = delivery.run
        def tracking_run(argv, **kwargs):
            if argv[0] == 'wl-copy':
                state['copied'] = kwargs['input'].decode('utf-8')
            if argv[:2] == ['hyprctl', 'dispatch'] and hyprland is not None:
                calls.append((argv, kwargs))
                return type('Result', (), {'returncode': 0 if hyprland else 1, 'stdout': 'ok' if hyprland else '', 'stderr': '' if hyprland else 'error: nil'})()
            return original_run(argv, **kwargs)
        delivery.run = tracking_run
        restored = []
        delivery.schedule_restore = lambda previous, ours, **_: restored.append((previous, ours))
        return delivery, target, calls, restored

    def test_paste_is_clipboard_then_one_chord_and_restores_earlier_text(self):
        delivery, target, calls, restored = self.make({'any_window': True})
        self.assertEqual(delivery.submit('Hello, 世界.\nSecond line', target), 'unknown')
        helpers = [a for a, _ in calls if a[0] in ('wl-copy', 'wtype')]
        self.assertEqual(helpers[0][:1], ['wl-copy'])
        self.assertEqual(helpers[1], ['wtype', '-M', 'ctrl', '-k', 'v', '-m', 'ctrl'])
        self.assertEqual(len(helpers), 2)
        dispatches = [a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']]
        self.assertEqual(len(dispatches), 2)
        self.assertIn('address:0x123', dispatches[0][2])
        self.assertIn('send_shortcut', dispatches[0][2])
        self.assertEqual([k['input'] for a, k in calls if a[0] == 'wl-copy'], ['Hello, 世界.\nSecond line'.encode()])
        self.assertEqual(restored, [('earlier text', 'Hello, 世界.\nSecond line')])
        self.assertNotIn('private', json.dumps(delivery.snapshot()))

    def test_terminal_uses_shift_chord_and_refuses_line_breaks_unless_allowed(self):
        delivery, target, calls, _ = self.make({'any_window': True}, terminal=True)
        self.assertEqual(delivery.submit('ls -la\nrm -rf /', target), 'unsupported_text')
        self.assertFalse([a for a, _ in calls if a[0] in ('wl-copy', 'wtype')])
        self.assertEqual(delivery.submit('echo hello', target), 'unknown')
        chord = [a for a, _ in calls if a[0] == 'wtype'][0]
        self.assertEqual(chord, ['wtype', '-M', 'ctrl', '-M', 'shift', '-k', 'v', '-m', 'shift', '-m', 'ctrl'])
        permissive, target, calls, _ = self.make({'any_window': True, 'allow_terminal_multiline': True}, terminal=True)
        self.assertEqual(permissive.submit('one\ntwo', target), 'unknown')

    def test_terminal_payload_is_stripped_and_the_exact_payload_is_checked(self):
        delivery, target, calls, _ = self.make({'any_window': True}, terminal=True)
        self.assertEqual(delivery.submit('echo hi\n', target), 'unknown')
        self.assertEqual(delivery.submit('echo hi\r\n\n', target), 'unknown')
        self.assertEqual([k['input'] for a, k in calls if a[0] == 'wl-copy'], [b'echo hi', b'echo hi'])
        calls.clear()
        for text in ('echo a\n\nrm b', 'echo a\rrm b', '\necho a'):
            self.assertEqual(delivery.submit(text, target), 'unsupported_text')
        self.assertFalse([a for a, _ in calls if a[0] in ('wl-copy', 'wtype')])

    def test_dispatcher_timeout_does_not_fall_back_to_untargeted_wtype(self):
        delivery, target, calls, restored = self.make({'any_window': True}, hyprland=True)
        inner = delivery.run
        def timing_out(argv, **kwargs):
            if argv[:2] == ['hyprctl', 'dispatch']:
                calls.append((argv, kwargs))
                raise subprocess.TimeoutExpired(argv, 5)
            return inner(argv, **kwargs)
        delivery.run = timing_out
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertFalse([a for a, _ in calls if a[0] == 'wtype'])
        self.assertEqual(len([a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']]), 1)

    def test_clean_dispatcher_failure_falls_back_only_while_the_target_is_active(self):
        delivery, target, calls, _ = self.make({'any_window': True}, hyprland=False)
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertEqual(len([a for a, _ in calls if a[0] == 'wtype']), 1)
        delivery, target, calls, _ = self.make({'any_window': True}, hyprland=False)
        snapshots = []
        def moving():
            snapshots.append(1)
            return target if len(snapshots) <= 2 else {**target, 'address': '0x999'}
        delivery.snapshot = moving
        self.assertEqual(delivery.submit('text', target), 'target_changed')
        self.assertFalse([a for a, _ in calls if a[0] == 'wtype'])

    def test_hyprland_delivers_the_chord_to_the_captured_window_without_wtype(self):
        delivery, target, calls, _ = self.make({'any_window': True}, hyprland=True)
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertFalse([a for a, _ in calls if a[0] == 'wtype'])
        dispatches = [a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']]
        self.assertEqual(len(dispatches), 1)
        self.assertIn('"CTRL"', dispatches[0][2])
        self.assertIn('address:0x123', dispatches[0][2])
        terminal, target, calls, _ = self.make({'any_window': True}, hyprland=True, terminal=True)
        terminal.submit('ls', target)
        self.assertIn('"CTRL SHIFT"', [a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']][0][2])

    def test_clipboard_that_never_becomes_live_sends_no_chord(self):
        delivery, target, calls, restored = self.make({'any_window': True})
        delivery.run = lambda argv, **kwargs: calls.append((argv, kwargs)) or type('Result', (), {'returncode': 0, 'stdout': json.dumps({'locked': False}) if argv[-1] == 'locked' else json.dumps({**target, 'title': 'private'}) if argv[-1] == 'activewindow' else ''})()
        delivery.clipboard = lambda: 'earlier text'
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertFalse([a for a, _ in calls if a[0] == 'wtype' or a[:2] == ['hyprctl', 'dispatch']])
        self.assertEqual(restored, [('earlier text', 'text')])

    @unittest.skipUnless(sys.platform == 'linux', 'reads /proc')
    def test_terminal_with_custom_window_class_is_recognised_by_its_process(self):
        delivery, target, calls, _ = self.make({'any_window': True}, hyprland=True)
        target['class'] = 'org.example.custom-shell'
        delivery.process_name = lambda pid: 'ghostty' if pid == 42 else None
        self.assertEqual(delivery.submit('ls -la\nrm -rf /', target), 'unsupported_text')
        self.assertEqual(delivery.submit('echo hello', target), 'unknown')
        self.assertIn('"CTRL SHIFT"', [a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']][0][2])
        plain, target, calls, _ = self.make({'any_window': True}, hyprland=True)
        plain.process_name = lambda pid: 'gedit'
        plain.submit('echo hello', target)
        self.assertIn('"CTRL"', [a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']][0][2])
        self.assertNotIn('SHIFT', [a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']][0][2])
        omarchy, target, calls, _ = self.make({'any_window': True}, hyprland=True)
        target['class'] = 'org.omarchy.agent'
        omarchy.process_name = lambda pid: None
        omarchy.submit('echo hello', target)
        self.assertIn('"CTRL SHIFT"', [a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']][0][2])
        from desktop import HyprlandDelivery
        import os
        real = HyprlandDelivery({'mode': 'paste', 'any_window': True, 'allow_unknown_secure_field': True})
        self.assertEqual(real.process_name(os.getpid()), open('/proc/self/comm').read().strip())
        self.assertIsNone(real.process_name(-1))
        self.assertIsNone(real.process_name('42'))

    def test_allowlist_any_window_and_control_characters(self):
        delivery, target, calls, _ = self.make({'allowed_classes': ['other']})
        self.assertEqual(delivery.submit('text', target), 'recover_only')
        delivery, target, calls, _ = self.make({'allowed_classes': ['editor']})
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertEqual(delivery.submit('bad\x1b[A', target), 'unsupported_text')
        self.assertEqual(delivery.submit('tab\tok', target), 'unknown')
        from desktop import HyprlandDelivery
        plain = HyprlandDelivery({'mode': 'paste', 'any_window': True}, run=lambda *a, **k: None)
        self.assertEqual(plain.submit('text', target), 'recover_only')

    def test_unreadable_or_disabled_clipboard_is_not_restored_and_target_change_aborts(self):
        from phrases import PhraseContextUnavailable
        delivery, target, calls, restored = self.make({'any_window': True}, clipboard=PhraseContextUnavailable('image'))
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertEqual(restored, [])
        delivery, target, calls, restored = self.make({'any_window': True, 'restore_clipboard': False})
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertEqual(restored, [])
        delivery, target, calls, restored = self.make({'any_window': True})
        self.assertEqual(delivery.submit('text', {**target, 'address': '0x999'}), 'target_changed')
        self.assertFalse([a for a, _ in calls if a[0] in ('wl-copy', 'wtype')])

    def test_restore_only_replaces_our_own_clipboard(self):
        from desktop import HyprlandDelivery
        calls = []
        delivery = HyprlandDelivery({'mode': 'paste', 'any_window': True, 'allow_unknown_secure_field': True},
                                    run=lambda argv, **k: calls.append((argv, k)))
        current = ['ours']
        delivery.clipboard = lambda: current[0]
        delivery.schedule_restore('before', 'ours', delay=0)
        time.sleep(.1)
        self.assertEqual([k['input'] for a, k in calls], [b'before'])
        current[0] = 'something newer'
        delivery.schedule_restore('before', 'ours', delay=0)
        time.sleep(.1)
        self.assertEqual(len(calls), 1)

    def test_paste_configuration_validation(self):
        from desktop import validate_config
        base = {'engine_config': '/local/engines.json'}
        validate_config({**base, 'delivery': {'mode': 'paste', 'any_window': True, 'allow_unknown_secure_field': True}})
        validate_config({**base, 'delivery': {'mode': 'paste', 'allowed_classes': ['editor'], 'terminal_classes': ['kitty']}})
        for delivery in ({'mode': 'paste'}, {'mode': 'paste', 'any_window': 'yes'},
                         {'mode': 'paste', 'any_window': True, 'restore_clipboard': 1},
                         {'mode': 'paste', 'allowed_classes': ['*']}, {'mode': 'paste', 'any_window': True, 'terminal_classes': 'kitty'}):
            with self.subTest(delivery=delivery), self.assertRaises(ValueError):
                validate_config({**base, 'delivery': delivery})

    def test_delivered_outcome_has_its_own_coarse_cue(self):
        class Feedback:
            def __init__(self):
                self.states, self.status = [], 'disabled'
            def notify(self, state):
                self.states.append(state)
        with tempfile.TemporaryDirectory() as temp:
            feedback = Feedback()
            session = Session(Capture(), Engine(), Delivery(), Path(temp), feedback=feedback)
            try:
                session.command('start')
                session.command('stop')
                session.wait()
                self.assertEqual(feedback.states, ['recording', 'transcribing', 'delivered'])
                self.assertNotIn(session.engine.text, json.dumps(feedback.states))
            finally:
                session.close()


class WatchStreamTests(unittest.TestCase):
    def test_level_from_pcm_bytes(self):
        from desktop import level_db
        import math
        self.assertEqual(level_db(b''), -120.0)
        self.assertEqual(level_db(b'\0\0' * 1600), -120.0)
        tone = bytes()
        import struct
        tone = b''.join(struct.pack('<h', int(0.5 * 32767 * math.sin(2 * math.pi * 440 * i / 16000))) for i in range(1600))
        self.assertAlmostEqual(level_db(tone), 20 * math.log10(0.5 / math.sqrt(2)), delta=.3)

    def test_watch_stream_reports_transitions_levels_and_service_exit(self):
        from desktop import serve, request, watch
        import io
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'session.sock'
            session = Session(Capture(), Engine(), Delivery(), Path(temp) / 'recovery')
            stopped = threading.Event()
            thread = threading.Thread(target=serve, args=(path, session, stopped), kwargs={'lifetime_seconds': 5})
            thread.start()
            output = io.StringIO()
            halt = threading.Event()
            watcher = threading.Thread(target=watch, args=(path, output), kwargs={'retry': True, 'stopped': halt, 'interval': .05})
            try:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    try:
                        request(path, 'status')
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        time.sleep(.005)
                watcher.start()
                time.sleep(.3)
                request(path, 'start')
                time.sleep(.3)
                request(path, 'stop')
                session.wait()
                time.sleep(.3)
                lines = [json.loads(line) for line in output.getvalue().splitlines()]
                states = [line.get('state') for line in lines if line.get('event') == 'state']
                self.assertEqual(states[0], 'idle')
                self.assertIn('recording', states)
                self.assertEqual(states[-1], 'idle')
                recording = [line for line in lines if line.get('state') == 'recording']
                self.assertTrue(all(isinstance(line['elapsed'], float) for line in recording))
                self.assertTrue(all(line['level'] is None or isinstance(line['level'], float) for line in recording))
                self.assertNotIn(session.engine.text, output.getvalue())
                self.assertNotIn('transcript', output.getvalue())
                stopped.set()
                thread.join(3)
                time.sleep(.3)
                tail = [json.loads(line) for line in output.getvalue().splitlines()][-2:]
                self.assertEqual([line.get('event') for line in tail], ['stopping', 'disconnected'])
            finally:
                halt.set()
                watcher.join(3)
                stopped.set()
                thread.join(3)
                session.close()
            self.assertFalse(watcher.is_alive())

    def test_watch_without_retry_exits_when_service_is_absent(self):
        from desktop import watch
        import io
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as temp:
            self.assertEqual(watch(Path(temp) / 'missing.sock', output), 0)
        self.assertEqual(json.loads(output.getvalue())['event'], 'disconnected')


class RetentionTests(unittest.TestCase):
    def take(self, root, name, *, age_days=0, audio_bytes=3200, transcript=True):
        path = root / (name * 32)
        path.mkdir(mode=0o700)
        (path / 'recording.wav').write_bytes(b'\0' * audio_bytes)
        if transcript:
            (path / 'transcript.txt').write_text('text')
        stamp = time.time() - age_days * 86400
        os.utime(path / 'recording.wav', (stamp, stamp))
        return path

    def test_cap_is_configurable_and_reported(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in 'abc':
                self.take(root, name)
            session = Session(Capture(), Engine(), Delivery(), root, maximum_takes=3)
            try:
                status = session.command('start')
                self.assertEqual((status['error'], status['takes'], status['maximum_takes']), ('recovery_full', 3, 3))
                self.assertEqual(session.capture.starts, 0)
            finally:
                session.close()
            session = Session(Capture(), Engine(), Delivery(), root, maximum_takes=4)
            try:
                self.assertEqual(session.command('start')['state'], 'recording')
            finally:
                session.close()

    def test_completed_audio_past_age_or_size_is_removed_but_text_and_recovery_audio_stay(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old = self.take(root, 'a', age_days=100)
            fresh = self.take(root, 'b', age_days=1)
            recovery_only = self.take(root, 'c', age_days=400, transcript=False)
            big = [self.take(root, chr(ord('d') + i), age_days=10 + i, audio_bytes=1024 * 1024) for i in range(3)]
            session = Session(Capture(), Engine(), Delivery(), root, audio_days=90, audio_megabytes=3)
            try:
                removed = session.retire_completed_audio()
            finally:
                session.close()
            self.assertFalse((old / 'recording.wav').exists())
            self.assertTrue((old / 'transcript.txt').exists())
            self.assertTrue((fresh / 'recording.wav').exists())
            self.assertTrue((recovery_only / 'recording.wav').exists())
            # Three 1 MiB completed WAVs over a 3 MiB limit: the oldest goes.
            self.assertFalse((big[2] / 'recording.wav').exists())
            self.assertTrue((big[0] / 'recording.wav').exists() and (big[1] / 'recording.wav').exists())
            self.assertEqual(removed, 2)

    def test_retention_runs_after_a_take_without_touching_the_new_one(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old = self.take(root, 'a', age_days=100)
            session = Session(Capture(), Engine(), Delivery(), root, audio_days=90)
            try:
                session.command('start')
                session.command('stop')
                session.wait()
                self.assertFalse((old / 'recording.wav').exists())
                self.assertTrue((session.take / 'recording.wav').exists())
            finally:
                session.close()

    def test_history_keep_forgets_everything_but_the_newest_takes_after_each_dictation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            olds = [self.take(root, chr(ord('a') + i), age_days=10 - i) for i in range(6)]
            session = Session(Capture(), Engine(), Delivery(), root, history_keep=5)
            try:
                self.assertEqual(session.prune_history(), 1)
                self.assertFalse(olds[0].exists())
                self.assertTrue(all(path.exists() for path in olds[1:]))
                session.command('start')
                session.command('stop')
                session.wait()
                remaining = sorted(p.name for p in root.iterdir())
                self.assertEqual(len(remaining), 5)
                self.assertIn(session.take.name, remaining)
                self.assertFalse(olds[1].exists())
                self.assertEqual((session.take / 'transcript.txt').read_text(), session.engine.text)
                self.assertEqual(session.command('status')['history_keep'], 5)
            finally:
                session.close()
            off = Session(Capture(), Engine(), Delivery(), root)
            try:
                self.assertEqual(off.prune_history(), 0)
                self.assertEqual(len(list(root.iterdir())), 5)
            finally:
                off.close()

    def test_history_orders_by_take_time_not_directory_mtime_after_audio_expiry(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old = self.take(root, 'a', age_days=100)
            recent = self.take(root, 'b', age_days=1)
            for path, days in ((old, 100), (recent, 1)):
                (path / 'take.json').write_text(json.dumps({'created': time.time() - days * 86400}))
                stamp = time.time() - days * 86400
                os.utime(path / 'transcript.txt', (stamp, stamp))
            session = Session(Capture(), Engine(), Delivery(), root, audio_days=90, history_keep=1)
            try:
                # Expiring the old WAV bumps the old directory's mtime to now.
                self.assertEqual(session.retire_completed_audio(), 1)
                self.assertGreater(old.stat().st_mtime, recent.stat().st_mtime)
                self.assertEqual(session.prune_history(), 1)
                self.assertFalse(old.exists())
                self.assertTrue(recent.exists())
            finally:
                session.close()

    def test_history_orders_legacy_takes_without_metadata_by_surviving_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            old = self.take(root, 'a', age_days=100)
            recent = self.take(root, 'b', age_days=1)
            stamp = time.time() - 100 * 86400
            os.utime(old / 'transcript.txt', (stamp, stamp))
            stamp = time.time() - 86400
            os.utime(recent / 'transcript.txt', (stamp, stamp))
            session = Session(Capture(), Engine(), Delivery(), root, audio_days=90, history_keep=1)
            try:
                session.retire_completed_audio()
                self.assertEqual(session.prune_history(), 1)
                self.assertFalse(old.exists())
                self.assertTrue(recent.exists())
            finally:
                session.close()

    def test_new_takes_record_their_creation_time_and_cancel_leaves_nothing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            session = Session(Capture(), Engine(), Delivery(), root)
            try:
                before = time.time()
                session.command('start')
                created = json.loads((session.take / 'take.json').read_text())['created']
                self.assertTrue(before <= created <= time.time())
                session.command('cancel')
                self.assertEqual(list(root.iterdir()), [])
            finally:
                session.close()

    def test_prune_never_deletes_a_take_recovered_while_it_is_choosing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            retried = self.take(root, 'a', age_days=5, transcript=False)
            newest = self.take(root, 'b', age_days=1)
            engine = Engine()
            engine.gate = threading.Event()
            session = Session(Capture(), engine, Delivery(), root, history_keep=1)
            results = []
            def retry():
                try:
                    session.recover_audio(retried.name)
                    results.append('accepted')
                except ValueError:
                    results.append('rejected')
            thread = threading.Thread(target=retry)
            real = Path.iterdir
            def iterdir(path):
                found = list(real(path))
                if path == root and not thread.ident:
                    # The retry arrives after the take list is built but before anything is deleted.
                    thread.start()
                    thread.join(.2)
                return iter(found)
            try:
                with unittest.mock.patch.object(Path, 'iterdir', iterdir):
                    session.prune_history()
                thread.join(2)
                if results == ['accepted']:
                    self.assertTrue((retried / 'recording.wav').exists())
                    self.assertEqual(session.take, retried)
                else:
                    self.assertEqual(results, ['rejected'])
                self.assertTrue(newest.exists())
                # Whatever happened, a later prune never takes the take being retried.
                engine.gate.set()
                session.wait()
            finally:
                engine.gate.set()
                session.close()

    def test_prune_skips_the_take_in_flight(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            retried = self.take(root, 'a', age_days=5, transcript=False)
            self.take(root, 'b', age_days=1)
            engine = Engine()
            engine.gate = threading.Event()
            session = Session(Capture(), engine, Delivery(), root, history_keep=1)
            try:
                session.recover_audio(retried.name)
                self.assertEqual(session.prune_history(), 0)
                self.assertTrue((retried / 'recording.wav').exists())
            finally:
                engine.gate.set()
                session.close()

    def test_configuration_bounds(self):
        from desktop import validate_config
        base = {'engine_config': '/local/engines.json'}
        config = validate_config(base)
        self.assertEqual((config['maximum_recovery_takes'], config['audio_retention_days'], config['audio_retention_megabytes'], config['history_keep']), (200, 90, 2048, None))
        self.assertEqual(validate_config({**base, 'history_keep': 5})['history_keep'], 5)
        with self.assertRaises(ValueError):
            validate_config({**base, 'history_keep': 0})
        converted = validate_config({**base, 'history_keep': 5.0})['history_keep']
        self.assertEqual((converted, type(converted)), (5, int))
        for bad in (5.5, True, float('nan'), '5'):
            with self.subTest(history_keep=bad), self.assertRaises(ValueError):
                validate_config({**base, 'history_keep': bad})
        validate_config({**base, 'audio_retention_days': None, 'audio_retention_megabytes': None, 'maximum_recovery_takes': 500})
        for change in ({'maximum_recovery_takes': 0}, {'maximum_recovery_takes': 5001}, {'audio_retention_days': 'forever'},
                       {'audio_retention_megabytes': -1}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_config({**base, **change})


class ClipboardGuardTests(unittest.TestCase):
    """Paste must not destroy a clipboard it cannot put back."""

    make = PasteDeliveryTests.make

    def copies(self, calls):
        return [a for a, _ in calls if a[0] in ('wl-copy', 'wtype') or a[:2] == ['hyprctl', 'dispatch']]

    def test_image_clipboard_is_left_untouched_and_the_transcript_stays_recoverable(self):
        delivery, target, calls, restored = self.make({'any_window': True})
        delivery.clipboard_types = lambda: ['image/png']
        self.assertEqual(delivery.submit('text', target), 'recover_only')
        self.assertFalse(self.copies(calls))
        self.assertEqual(restored, [])

    def test_file_list_and_images_with_a_text_flavour_are_also_left_alone(self):
        for types in (['text/uri-list', 'text/plain', 'x-special/gnome-copied-files'],
                      ['text/plain;charset=utf-8', 'image/png'], ['application/pdf']):
            with self.subTest(types=types):
                delivery, target, calls, restored = self.make({'any_window': True})
                delivery.clipboard_types = lambda types=types: types
                self.assertEqual(delivery.submit('text', target), 'recover_only')
                self.assertFalse(self.copies(calls))

    def test_oversized_text_clipboard_is_left_untouched(self):
        from desktop import ClipboardTooLarge
        delivery, target, calls, restored = self.make({'any_window': True}, clipboard=ClipboardTooLarge('big'))
        delivery.clipboard_types = lambda: ['text/plain;charset=utf-8']
        self.assertEqual(delivery.submit('text', target), 'recover_only')
        self.assertFalse(self.copies(calls))

    def test_rich_text_is_restored_as_plain_text_and_disabled_restore_skips_the_check(self):
        delivery, target, calls, restored = self.make({'any_window': True})
        delivery.clipboard_types = lambda: ['text/html', 'text/plain;charset=utf-8', 'UTF8_STRING']
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertEqual(restored, [('earlier text', 'text')])
        delivery, target, calls, restored = self.make({'any_window': True, 'restore_clipboard': False})
        delivery.clipboard_types = lambda: self.fail('restore is off, so the clipboard is never inspected')
        self.assertEqual(delivery.submit('text', target), 'unknown')

    def test_password_manager_hint_is_overwritten_but_never_restored(self):
        delivery, target, calls, restored = self.make({'any_window': True}, clipboard='hunter2')
        delivery.clipboard_types = lambda: ['text/plain;charset=utf-8', 'x-kde-passwordManagerHint']
        self.assertEqual(delivery.submit('text', target), 'unknown')
        self.assertEqual([k['input'] for a, k in calls if a[0] == 'wl-copy'], [b'text'])
        self.assertEqual(restored, [])

    def test_empty_or_unlistable_clipboard_still_pastes(self):
        for types in ([], None):
            delivery, target, calls, restored = self.make({'any_window': True}, clipboard=OSError('nothing'))
            delivery.clipboard_types = lambda types=types: types
            self.assertEqual(delivery.submit('text', target), 'unknown')
            self.assertEqual(restored, [])

    def test_clipboard_types_reads_wl_paste_list_types(self):
        from desktop import HyprlandDelivery
        def runner(result=None, error=None):
            def run(argv, **kwargs):
                self.assertEqual(argv, ['wl-paste', '--list-types'])
                if error:
                    raise error
                return result
            return run
        Result = lambda code, out='': type('Result', (), {'returncode': code, 'stdout': out})()
        config = {'mode': 'paste'}
        self.assertEqual(HyprlandDelivery(config, run=runner(Result(0, 'text/plain\nimage/png\n'))).clipboard_types(),
                         ['text/plain', 'image/png'])
        self.assertEqual(HyprlandDelivery(config, run=runner(Result(1))).clipboard_types(), [])
        self.assertIsNone(HyprlandDelivery(config, run=runner(error=OSError())).clipboard_types())
        self.assertIsNone(HyprlandDelivery(config, run=runner(error=subprocess.TimeoutExpired('wl-paste', 1))).clipboard_types())

    def test_read_phrase_clipboard_over_the_cap_raises_the_too_large_error(self):
        from desktop import ClipboardTooLarge, read_phrase_clipboard
        with self.assertRaises(ClipboardTooLarge):
            read_phrase_clipboard([sys.executable, '-c', 'print("x" * 100)'], maximum=10)

    def test_restore_delay_comes_from_configuration_with_a_longer_default(self):
        from desktop import HyprlandDelivery
        for config, expected in (({'mode': 'paste'}, 1.5), ({'mode': 'paste', 'restore_delay_seconds': 3}, 3)):
            delays = []
            delivery = HyprlandDelivery(config, run=lambda *a, **k: None)
            delivery.clipboard = lambda: 'other'
            with unittest.mock.patch('desktop.time.sleep', side_effect=delays.append):
                delivery.schedule_restore('before', 'ours')
                delivery.restore_thread.join(2)
            self.assertEqual(delays, [expected])

    def test_restore_delay_is_validated(self):
        from desktop import validate_config
        base = {'engine_config': '/local/engines.json'}
        validate_config({**base, 'delivery': {'mode': 'recover', 'restore_delay_seconds': 2.5}})
        for bad in (0, .05, 31, 'soon', None, True, float('inf')):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                validate_config({**base, 'delivery': {'mode': 'recover', 'restore_delay_seconds': bad}})

    def test_truncated_process_name_matches_gnome_terminal_server(self):
        delivery, target, calls, restored = self.make({'any_window': True})
        probe = {'class': 'custom', 'pid': 7}
        delivery.process_name = lambda pid: 'gnome-terminal-'
        self.assertTrue(delivery.is_terminal(probe))
        delivery.process_name = lambda pid: 'firefox'
        self.assertFalse(delivery.is_terminal(probe))
        delivery.process_name = lambda pid: None
        self.assertFalse(delivery.is_terminal(probe))


class BlockingDelivery(Delivery):
    def __init__(self):
        super().__init__()
        self.inside, self.release = threading.Event(), threading.Event()

    def submit(self, text, target):
        self.calls.append((text, target))
        self.inside.set()
        self.release.wait(5)
        return 'unknown'


class DeliveryOutsideLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.delivery = BlockingDelivery()
        self.session = Session(Capture(), Engine(), self.delivery, Path(self.temp.name))
        self.addCleanup(self.session.close)
        self.addCleanup(self.delivery.release.set)

    def start_delivery(self):
        self.session.command('start')
        self.session.command('stop')
        self.assertTrue(self.delivery.inside.wait(3))

    def from_another_thread(self, call):
        box = []
        thread = threading.Thread(target=lambda: box.append(call()))
        thread.start()
        thread.join(1)
        self.assertFalse(thread.is_alive(), 'the session lock is held during delivery')
        return box[0]

    def test_status_tick_and_level_do_not_wait_for_a_slow_paste(self):
        self.start_delivery()
        self.assertEqual(self.from_another_thread(self.session.status)['state'], 'transcribing')
        self.from_another_thread(self.session.tick)
        self.assertIsNone(self.from_another_thread(self.session.level))
        self.assertIsNone(self.from_another_thread(self.session.elapsed))
        self.delivery.release.set()
        self.session.wait()
        self.assertEqual((self.session.state, self.session.outcome), ('idle', 'unknown'))

    def test_a_new_take_cannot_start_underneath_a_delivery(self):
        self.start_delivery()
        self.assertEqual(self.from_another_thread(lambda: self.session.command('start'))['state'], 'transcribing')
        self.assertEqual(len(self.delivery.calls), 1)
        self.delivery.release.set()
        self.session.wait()

    def test_cancel_during_delivery_settles_idle_and_keeps_the_transcript(self):
        self.start_delivery()
        self.from_another_thread(lambda: self.session.command('cancel'))
        take = self.session.take
        self.delivery.release.set()
        self.session.wait()
        self.assertEqual(self.session.state, 'idle')
        self.assertEqual((take / 'transcript.txt').read_text(), Engine().text)
        # The text did go out, so the outcome says so instead of claiming it was never attempted.
        self.assertEqual(self.session.outcome, 'unknown')
        self.assertEqual(self.session.command('start')['state'], 'recording')

    def test_close_during_delivery_neither_hangs_nor_raises(self):
        self.start_delivery()
        closer = threading.Thread(target=self.session.close)
        closer.start()
        time.sleep(.1)
        self.delivery.release.set()
        closer.join(5)
        self.assertFalse(closer.is_alive())
        self.assertEqual(self.session.state, 'idle')


class CancelDuringDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def test_cancel_before_the_clipboard_is_touched_stops_the_paste(self):
        delivery, target, calls, restored = PasteDeliveryTests().make({'any_window': True}, hyprland=True)
        inspecting, release = threading.Event(), threading.Event()
        def clipboard_types():
            inspecting.set()
            release.wait(5)
            return ['text/plain']
        delivery.clipboard_types = clipboard_types
        session = Session(Capture(), Engine(), delivery, Path(self.temp.name))
        self.addCleanup(session.close)
        self.addCleanup(release.set)
        session.command('start')
        session.command('stop')
        self.assertTrue(inspecting.wait(3))
        session.command('cancel')
        release.set()
        session.wait()
        self.assertFalse([a for a, _ in calls if a[0] in ('wl-copy', 'wtype') or a[:2] == ['hyprctl', 'dispatch']])
        self.assertEqual((session.state, session.outcome), ('idle', 'not_attempted'))

    def test_cancel_after_the_clipboard_is_set_skips_the_chord_and_restores(self):
        delivery, target, calls, restored = PasteDeliveryTests().make({'any_window': True}, hyprland=True)
        cancelled = threading.Event()
        inner = delivery.run
        def run(argv, **kwargs):
            result = inner(argv, **kwargs)
            if argv[0] == 'wl-copy':
                cancelled.set()
            return result
        delivery.run = run
        self.assertEqual(delivery.submit('text', target, cancelled=cancelled), 'not_attempted')
        self.assertFalse([a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch'] or a[0] == 'wtype'])
        self.assertEqual(restored, [('earlier text', 'text')])

    def test_cancel_while_the_first_dispatch_runs_skips_the_fallbacks(self):
        delivery, target, calls, restored = PasteDeliveryTests().make({'any_window': True}, hyprland=False)
        cancelled = threading.Event()
        inner = delivery.run
        def run(argv, **kwargs):
            result = inner(argv, **kwargs)
            if argv[:2] == ['hyprctl', 'dispatch']:
                cancelled.set()
            return result
        delivery.run = run
        self.assertEqual(delivery.submit('text', target, cancelled=cancelled), 'not_attempted')
        self.assertEqual(len([a for a, _ in calls if a[:2] == ['hyprctl', 'dispatch']]), 1)
        self.assertFalse([a for a, _ in calls if a[0] == 'wtype'])

    def test_type_mode_honours_a_cancel_before_wtype(self):
        from desktop import HyprlandDelivery
        calls = []
        target = {'address': '0x1', 'class': 'editor', 'pid': 4}
        def run(argv, **kwargs):
            calls.append(argv)
            out = json.dumps({'locked': False}) if argv[-1] == 'locked' else json.dumps(target)
            return type('Result', (), {'stdout': out, 'returncode': 0})()
        delivery = HyprlandDelivery({'mode': 'type', 'any_window': True, 'allow_unknown_secure_field': True}, run=run)
        cancelled = threading.Event()
        cancelled.set()
        self.assertEqual(delivery.submit('text', target, cancelled=cancelled), 'not_attempted')
        self.assertFalse([a for a in calls if a[0] == 'wtype'])

    def test_close_still_closes_the_engine_when_delivery_outlasts_the_wait(self):
        class Closing(Engine):
            closed = False
            def close(self):
                self.closed = True
        engine = Closing()
        session = Session(Capture(), engine, Delivery(), Path(self.temp.name))
        with unittest.mock.patch.object(Session, 'wait', side_effect=TimeoutError('Inference did not stop')):
            with self.assertRaises(TimeoutError):
                session.close()
        self.assertTrue(engine.closed)


class WatcherRaceTests(unittest.TestCase):
    class StubSession:
        def __init__(self):
            self.state = 'transcribing'
        def tick(self):
            pass
        def status(self):
            return {'state': self.state, 'error': None, 'delivery': 'x', 'recovery': None}
        def elapsed(self):
            return None
        def level(self):
            return None

    def read_events(self, connection, wanted, seconds=3):
        connection.settimeout(.2)
        buffer, events = b'', []
        end = time.monotonic() + seconds
        while time.monotonic() < end and wanted not in [e.get('state') for e in events]:
            try:
                chunk = connection.recv(65536)
            except socket.timeout:
                continue
            if not chunk:
                break
            buffer += chunk
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                events.append(json.loads(line))
        return [e.get('state') for e in events]

    def test_idle_reaches_existing_watchers_when_a_new_one_connects_just_after_it(self):
        from desktop import serve
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'session.sock'
            session = self.StubSession()
            stopped = threading.Event()
            thread = threading.Thread(target=serve, args=(path, session, stopped), kwargs={'lifetime_seconds': 10})
            thread.start()
            connections = []
            try:
                deadline = time.monotonic() + 3
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
                def watch():
                    connection = socket.socket(socket.AF_UNIX)
                    connection.connect(str(path))
                    connection.sendall(json.dumps({'action': 'watch'}).encode() + b'\n')
                    connections.append(connection)
                    return connection
                first = watch()
                self.assertEqual(self.read_events(first, 'transcribing'), ['transcribing'])
                time.sleep(.3)
                # The state flips and a second watcher connects before the loop's next broadcast.
                session.state = 'idle'
                second = watch()
                self.assertIn('idle', self.read_events(second, 'idle'))
                self.assertIn('idle', self.read_events(first, 'idle'))
            finally:
                stopped.set()
                thread.join(3)
                for connection in connections:
                    connection.close()


class CliModuleTests(unittest.TestCase):
    EXAMPLE = '''import json

def register(subparsers):
    command = subparsers.add_parser('example')
    command.add_argument('word')

def run(args, context):
    print(json.dumps({'word': args.word, 'config': str(context.config), 'recovery': str(context.recovery),
                      'imports': str(context.imports), 'runtime': str(context.runtime),
                      'socket': str(context.socket), 'callable': callable(context.request)}))
    return 3
'''

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / 'modules'
        self.directory.mkdir()

    def invoke(self, *arguments):
        import contextlib
        import io
        from desktop import main
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = main(['--config', '/c/linux.json', '--runtime', '/r', '--recovery', '/rec', '--imports', '/imp',
                         *arguments], cli_directory=self.directory)
        return code, out.getvalue(), err.getvalue()

    def test_a_cli_module_is_loaded_registered_and_run_with_the_context(self):
        (self.directory / 'cli_example.py').write_text(self.EXAMPLE)
        code, out, _ = self.invoke('example', 'hello')
        self.assertEqual(code, 3)
        self.assertEqual(json.loads(out), {'word': 'hello', 'config': '/c/linux.json', 'recovery': '/rec',
                                           'imports': '/imp', 'runtime': '/r', 'socket': '/r/session.sock',
                                           'callable': True})

    def test_the_request_helper_talks_to_the_service_socket(self):
        from desktop import CliContext, serve
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'session.sock'
            session = Session(Capture(), Engine(), Delivery(), Path(temp) / 'recovery')
            stopped = threading.Event()
            thread = threading.Thread(target=serve, args=(path, session, stopped), kwargs={'lifetime_seconds': 5})
            thread.start()
            try:
                deadline = time.monotonic() + 3
                while not path.exists() and time.monotonic() < deadline:
                    time.sleep(.005)
                import desktop
                context = CliContext(Path('c'), Path('r'), Path('i'), Path(temp), path,
                                     lambda action, identity=None, **fields: desktop.request(path, action, identity, **fields))
                self.assertEqual(context.request('status')['state'], 'idle')
            finally:
                stopped.set()
                thread.join(3)
                session.close()

    def test_a_broken_module_is_skipped_and_core_commands_still_work(self):
        (self.directory / 'cli_broken.py').write_text('def register(:\n')
        (self.directory / 'cli_incomplete.py').write_text('def register(subparsers):\n    pass\n')
        (self.directory / 'cli_explodes.py').write_text(
            'def register(subparsers):\n    subparsers.add_parser("half")\n    raise RuntimeError("no")\n'
            'def run(args, context):\n    return 0\n')
        (self.directory / 'cli_example.py').write_text(self.EXAMPLE)
        code, out, err = self.invoke('example', 'ok')
        self.assertEqual(code, 3)
        self.assertEqual(len(err.strip().splitlines()), 3)
        self.assertEqual({json.loads(line)['module'] for line in err.splitlines()},
                         {'cli_broken', 'cli_incomplete', 'cli_explodes'})
        with self.assertRaises(SystemExit):
            self.invoke('half')

    def test_a_module_cannot_replace_a_core_command(self):
        (self.directory / 'cli_hijack.py').write_text(
            'import json\ndef register(subparsers):\n    subparsers.add_parser("capabilities")\n'
            'def run(args, context):\n    print("hijacked")\n    return 9\n')
        code, out, err = self.invoke('capabilities')
        self.assertEqual(code, 0)
        self.assertNotIn('hijacked', out)
        self.assertIn('"interface"', out)

    def test_without_modules_the_cli_is_unchanged(self):
        code, out, _ = self.invoke('capabilities')
        self.assertEqual(code, 0)

    def test_the_default_directory_is_the_one_beside_desktop_py(self):
        from desktop import load_cli_modules
        self.assertEqual([m for m in load_cli_modules() if m.__file__ and Path(m.__file__).parent != Path(__file__).resolve().parent], [])


class WorkerParentWatchTests(unittest.TestCase):
    def test_workers_and_their_children_die_when_the_service_is_killed(self):
        import signal
        here = str(Path(__file__).resolve().parent)
        child = ('import subprocess, sys, time\n'
                 'grandchild = subprocess.Popen(["sleep", "60"])\n'
                 'print(grandchild.pid, flush=True)\n'
                 'time.sleep(60)\n')
        parent = ('import subprocess, sys, time\n'
                  'sys.path.insert(0, %r)\n'
                  'from desktop import guarded_command\n'
                  'worker = subprocess.Popen(guarded_command([sys.executable, "-c", sys.argv[1]]), stdout=subprocess.PIPE, text=True, start_new_session=True)\n'
                  'print(worker.pid, flush=True)\n'
                  'print(worker.stdout.readline().strip(), flush=True)\n'
                  'time.sleep(60)\n') % here
        script = Path(tempfile.mkdtemp()) / 'child.py'
        script.write_text(child)
        self.addCleanup(script.unlink)
        # guarded_command runs a script path, so hand it the child file rather than inline code.
        parent = parent.replace('[sys.executable, "-c", sys.argv[1]]', '[sys.executable, sys.argv[1]]')
        service = subprocess.Popen([sys.executable, '-c', parent, str(script)], stdout=subprocess.PIPE, text=True)
        pids = []
        try:
            pids = [int(service.stdout.readline()), int(service.stdout.readline())]
            for pid in pids:
                os.kill(pid, 0)
            service.kill()
            service.wait(5)
            deadline = time.monotonic() + 8
            alive = list(pids)
            while alive and time.monotonic() < deadline:
                time.sleep(.1)
                alive = [pid for pid in alive if self.alive(pid)]
            self.assertEqual(alive, [])
        finally:
            service.kill()
            service.wait(5)
            service.stdout.close()
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def test_a_guarded_worker_still_runs_its_script_with_its_arguments(self):
        from desktop import guarded_command
        with tempfile.TemporaryDirectory() as temp:
            script = Path(temp) / 'echo.py'
            script.write_text('import json, sys\nprint(json.dumps([sys.argv, __name__, __file__ == %r]))\n' % str(script))
            out = subprocess.run(guarded_command([sys.executable, str(script), 'speech']), capture_output=True,
                                 text=True, timeout=10, check=True).stdout
        self.assertEqual(json.loads(out), [[str(script), 'speech'], '__main__', True])
