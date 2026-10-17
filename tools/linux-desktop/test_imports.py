import functools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave

import desktop
import imports
from imports import FileError, FileTranscription


HERE = Path(__file__).resolve().parent


def write_wav(path, frames=16000, *, rate=16000, channels=1):
    with wave.open(str(path), 'wb') as audio:
        audio.setparams((channels, 2, rate, 0, 'NONE', ''))
        audio.writeframes(b'\0\0' * frames * channels)


class Engine:
    def __init__(self, text='hello comma world new paragraph  Thanks'):
        self.text, self.calls, self.seconds = text, 0, []
        self.gate = None
        self.entered = threading.Event()

    def transcribe(self, path, cancelled, *, seconds=None):
        self.calls += 1
        self.seconds.append(seconds)
        self.path = Path(path)
        self.frames = imports.inspect_wav(path)
        self.entered.set()
        if self.gate:
            while not self.gate.wait(.005):
                if cancelled.is_set():
                    raise RuntimeError('Speech engine unavailable')
        return self.text

    def close(self):
        pass


def probe_ok(source):
    return {'format': 'wav', 'duration': 1.0}


def probe_error(code):
    def prober(source):
        raise FileError(code)
    return prober


def decoder_frames(frames=16000):
    def decoder(source, destination, cancelled, **_):
        write_wav(destination, frames)
        return imports.inspect_wav(destination)
    return decoder


class FileTranscriptionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'talk.wav'
        write_wav(self.source, 48000, rate=48000, channels=2)
        self.original = self.source.read_bytes()
        self.engine = Engine()
        self.files = FileTranscription(self.engine, self.root / 'imports', prober=probe_ok, decoder=decoder_frames(32000))
        self.addCleanup(self.files.close)

    def start(self, source=None, **kwargs):
        return self.files.start(str(source or self.source), **kwargs)

    def wait(self):
        self.files.wait(5)

    def test_result_is_raw_private_and_separate_from_dictation_history(self):
        status = self.start()
        self.assertTrue(status['accepted'])
        self.wait()
        status = self.files.status()
        self.assertEqual((status['state'], status['error']), ('finished', None))
        self.assertEqual(status['duration_seconds'], 2.0)
        self.assertEqual(status['format'], 'wav')
        serialized = json.dumps(status)
        self.assertNotIn(str(self.source), serialized)
        self.assertNotIn('hello', serialized)
        job = self.root / 'imports' / status['id']
        transcript = job / 'transcript.txt'
        # No cleanup, spelling or phrase rule touches a file transcript.
        self.assertEqual(transcript.read_text(encoding='utf-8'), self.engine.text)
        self.assertEqual(transcript.stat().st_mode & 0o777, 0o600)
        self.assertFalse((job / 'decoded.wav').exists())
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(imports.result_text(self.root / 'imports'), self.engine.text)
        self.assertFalse((self.root / 'recovery').exists())
        self.assertGreaterEqual(self.engine.seconds[0], 60 + 2.0)
        self.assertEqual(self.engine.frames, 32000)

    def test_empty_recognition_is_a_distinct_state_with_a_saved_empty_result(self):
        self.engine.text = '  '
        self.start()
        self.wait()
        self.assertEqual(self.files.status()['state'], 'empty')
        self.assertEqual(imports.result_text(self.root / 'imports'), '  ')

    def test_source_checks_refuse_before_any_job_directory_exists(self):
        huge = self.root / 'huge.wav'
        with huge.open('wb') as output:
            output.truncate(imports.MAXIMUM_SOURCE_BYTES + 1)
        empty = self.root / 'empty.wav'
        empty.touch()
        for source, code in ((huge, 'too_large'), (empty, 'empty'), (self.root / 'missing.wav', 'invalid_audio'),
                             (self.root, 'unsupported_format')):
            with self.subTest(code=code):
                status = self.start(source)
                self.assertEqual((status['accepted'], status['error'], status['state']), (False, code, 'idle'))
        self.assertEqual(list((self.root / 'imports').iterdir()), [])
        self.assertIsNone(self.files.status()['error'])

    def test_probe_refusals_fail_cleanly_and_allow_retry(self):
        for code in ('unsupported_format', 'too_long', 'invalid_audio', 'decoder_unavailable'):
            with self.subTest(code=code):
                self.files.probe = probe_error(code)
                self.assertTrue(self.start()['accepted'])
                self.wait()
                self.assertEqual((self.files.status()['state'], self.files.status()['error']), ('failed', code))
                self.assertFalse(list((self.root / 'imports').glob('*/decoded.wav')))
        self.files.probe = probe_ok
        self.start()
        self.wait()
        self.assertEqual(self.files.status()['state'], 'finished')
        self.assertEqual(len(list((self.root / 'imports').iterdir())), 1)

    def test_decoded_audio_limits(self):
        for frames, code in ((0, 'empty'), (imports.MAXIMUM_FRAMES + 1, 'too_long')):
            with self.subTest(code=code):
                path = self.root / f'decoded-{frames}.wav'
                write_wav(path, frames)
                with self.assertRaises(FileError) as refused:
                    imports.inspect_wav(path)
                self.assertEqual(refused.exception.code, code)
        stereo = self.root / 'stereo.wav'
        write_wav(stereo, 100, channels=2)
        with self.assertRaises(FileError) as refused:
            imports.inspect_wav(stereo)
        self.assertEqual(refused.exception.code, 'invalid_audio')
        with self.assertRaises(FileError):
            imports.inspect_wav(self.root / 'missing.wav')

    def test_cancel_during_decode_stops_owned_process_and_permits_retry(self):
        fake = self.root / 'ffmpeg.py'
        fake.write_text('import time\nwhile True: time.sleep(.01)\n')
        self.files.decoder = functools.partial(imports.decode, command=[sys.executable, str(fake)])
        started = threading.Event()
        original = subprocess.Popen
        pids = []

        def popen(*args, **kwargs):
            process = original(*args, **kwargs)
            pids.append(process.pid)
            started.set()
            return process
        imports.subprocess.Popen = popen
        try:
            self.start()
            self.assertTrue(started.wait(2))
            time.sleep(.05)
            status = self.files.cancel()
            self.assertIn(status['state'], ('cancelling', 'cancelled'))
            self.wait()
        finally:
            imports.subprocess.Popen = original
        self.assertEqual((self.files.status()['state'], self.files.status()['error']), ('cancelled', None))
        with self.assertRaises(ProcessLookupError):
            os.kill(pids[0], 0)
        self.assertFalse(list((self.root / 'imports').glob('*/decoded.wav')))
        self.assertEqual(self.engine.calls, 0)
        self.files.decoder = decoder_frames()
        self.assertTrue(self.start()['accepted'])
        self.wait()
        self.assertEqual(self.files.status()['state'], 'finished')

    def test_decode_deadline_fails_without_inference(self):
        fake = self.root / 'ffmpeg.py'
        fake.write_text('import time\nwhile True: time.sleep(.01)\n')
        self.files.decoder = functools.partial(imports.decode, command=[sys.executable, str(fake)])
        self.files.decode_seconds = .1
        self.start()
        self.wait()
        self.assertEqual((self.files.status()['state'], self.files.status()['error']), ('failed', 'decoder_timeout'))
        self.assertEqual(self.engine.calls, 0)

    def test_cancel_during_inference_publishes_nothing(self):
        self.engine.gate = threading.Event()
        self.start()
        self.assertTrue(self.engine.entered.wait(2))
        self.assertEqual(self.files.status()['state'], 'transcribing')
        self.files.cancel()
        self.assertEqual(self.files.status()['state'], 'cancelling')
        self.assertEqual(self.start()['error'], 'busy')
        self.engine.gate.set()
        self.wait()
        self.assertEqual(self.files.status()['state'], 'cancelled')
        self.assertFalse(list((self.root / 'imports').glob('*/transcript.txt')))
        self.assertFalse(list((self.root / 'imports').glob('*/decoded.wav')))
        with self.assertRaises(FileError):
            imports.result_text(self.root / 'imports')

    def test_one_job_at_a_time_and_session_activity_refuses_without_side_effects(self):
        self.engine.gate = threading.Event()
        first = self.start()
        self.assertTrue(self.engine.entered.wait(2))
        second = self.start()
        self.assertEqual((second['accepted'], second['error'], second['id']), (False, 'busy', first['id']))
        self.engine.gate.set()
        self.wait()
        self.assertEqual(self.files.status()['state'], 'finished')
        refused = self.start(session_busy=True)
        self.assertEqual((refused['accepted'], refused['error']), (False, 'session_active'))
        self.assertEqual(self.files.status()['state'], 'finished')
        self.assertEqual(self.files.status()['error'], None)
        self.assertEqual(len(list((self.root / 'imports').iterdir())), 1)

    def test_new_job_replaces_previous_result_and_forget_removes_it(self):
        self.start()
        self.wait()
        previous = self.files.status()['id']
        self.start()
        self.wait()
        self.assertFalse((self.root / 'imports' / previous).exists())
        self.assertEqual(len(list((self.root / 'imports').iterdir())), 1)
        self.assertEqual(self.files.forget()['state'], 'idle')
        self.assertEqual(list((self.root / 'imports').iterdir()), [])
        self.engine.gate = threading.Event()
        self.start()
        self.assertTrue(self.engine.entered.wait(2))
        self.assertEqual(self.files.forget()['error'], 'busy')
        self.engine.gate.set()
        self.wait()

    def test_startup_adopts_finished_result_and_removes_interrupted_jobs(self):
        self.start()
        self.wait()
        finished = self.files.status()['id']
        stale = self.root / 'imports' / ('c' * 32)
        stale.mkdir(mode=0o700)
        write_wav(stale / 'decoded.wav')
        (stale / 'source.json').write_text('{"source": "/x"}')
        self.files.close()
        again = FileTranscription(Engine(), self.root / 'imports', prober=probe_ok, decoder=decoder_frames())
        self.addCleanup(again.close)
        self.assertEqual((again.status()['state'], again.status()['id']), ('finished', finished))
        self.assertEqual(again.status()['duration_seconds'], 2.0)
        self.assertFalse(stale.exists())

    def test_save_refuses_the_source_and_existing_files_unless_asked(self):
        self.start()
        self.wait()
        root = self.root / 'imports'
        for destination in (self.source, self.root / 'sub' / '..' / 'talk.wav'):
            with self.subTest(destination=str(destination)), self.assertRaises(FileError) as refused:
                imports.save_text(root, destination)
            self.assertEqual(refused.exception.code, 'cannot_replace_source')
        link = self.root / 'alias.txt'
        link.symlink_to(self.source)
        with self.assertRaises(FileError) as refused:
            imports.save_text(root, link, overwrite=True)
        self.assertEqual(refused.exception.code, 'cannot_replace_source')
        self.assertEqual(self.source.read_bytes(), self.original)
        target = self.root / 'notes.txt'
        imports.save_text(root, target)
        self.assertEqual(target.read_text(encoding='utf-8'), self.engine.text)
        with self.assertRaises(FileError) as refused:
            imports.save_text(root, target)
        self.assertEqual(refused.exception.code, 'destination_exists')
        self.engine.text = 'second'
        self.start()
        self.wait()
        imports.save_text(root, target, overwrite=True)
        self.assertEqual(target.read_text(encoding='utf-8'), 'second')
        with self.assertRaises(FileError) as refused:
            imports.save_text(root, self.root, overwrite=True)
        self.assertEqual(refused.exception.code, 'invalid_destination')
        self.assertTrue(imports.forget_result(root))
        with self.assertRaises(FileError) as refused:
            imports.save_text(root, self.root / 'later.txt')
        self.assertEqual(refused.exception.code, 'no_result')

    def test_shared_import_directory_is_refused(self):
        shared = self.root / 'shared'
        shared.mkdir(mode=0o755)
        shared.chmod(0o755)
        with self.assertRaises(ValueError):
            FileTranscription(Engine(), shared)


class CommandTests(unittest.TestCase):
    def test_helper_commands_pass_paths_as_single_arguments_and_never_read_stdin(self):
        source, target = Path('/tmp/with space.m4a'), Path('/tmp/out.wav')
        probe = imports.probe_command(source)
        decode = imports.decode_command(source, target)
        self.assertEqual(probe[0], 'ffprobe')
        self.assertEqual(probe[-1], str(source))
        self.assertEqual(decode[0], 'ffmpeg')
        self.assertIn('-nostdin', decode)
        self.assertEqual(decode[decode.index('-i') + 1], str(source))
        self.assertEqual(decode[-1], str(target))
        self.assertEqual(decode[decode.index('-ar') + 1:decode.index('-ar') + 2], ['16000'])
        self.assertEqual(decode[decode.index('-ac') + 1], '1')

    def test_probe_identifies_containers_and_refuses_others(self):
        def fake(report, returncode=0):
            script = Path(tempfile.mkdtemp()) / 'probe.py'
            script.write_text('import sys\nsys.stdout.write(' + repr(json.dumps(report)) + ')\nsys.exit(' + str(returncode) + ')\n')
            return [sys.executable, str(script)]
        audio = [{'codec_type': 'audio', 'duration': '2.0'}]
        cases = (({'format': {'format_name': 'wav', 'duration': '2.0'}, 'streams': audio}, ('wav', 2.0)),
                 ({'format': {'format_name': 'aiff'}, 'streams': audio}, ('aiff', 2.0)),
                 ({'format': {'format_name': 'mov,mp4,m4a,3gp,3g2,mj2', 'duration': '3.5'}, 'streams': audio}, ('m4a', 3.5)))
        for report, expected in cases:
            with self.subTest(expected=expected):
                result = imports.probe('/unused', command=fake(report))
                self.assertEqual((result['format'], result['duration']), expected)
        refusals = (({'format': {'format_name': 'mp3', 'duration': '2'}, 'streams': audio}, 'unsupported_format'),
                    ({'format': {'format_name': 'wav', 'duration': '2'}, 'streams': []}, 'invalid_audio'),
                    ({'format': {'format_name': 'wav', 'duration': '601.5'}, 'streams': audio}, 'too_long'),
                    ({'format': {'format_name': 'wav', 'duration': '0'}, 'streams': [{'codec_type': 'audio'}]}, 'empty'),
                    ({'format': {'format_name': 'wav', 'duration': 'nan'}, 'streams': audio}, 'invalid_audio'),
                    ({'format': {}}, 'invalid_audio'))
        for report, code in refusals:
            with self.subTest(code=code), self.assertRaises(FileError) as refused:
                imports.probe('/unused', command=fake(report))
            self.assertEqual(refused.exception.code, code)
        with self.assertRaises(FileError) as refused:
            imports.probe('/unused', command=fake({}, returncode=1))
        self.assertEqual(refused.exception.code, 'invalid_audio')
        with self.assertRaises(FileError) as refused:
            imports.probe('/unused', command=['/nonexistent/ffprobe'])
        self.assertEqual(refused.exception.code, 'decoder_unavailable')

    def test_decode_refuses_failed_or_missing_decoder_and_keeps_destination_private(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            failing = root / 'ffmpeg.py'
            failing.write_text('import sys\nsys.exit(1)\n')
            with self.assertRaises(FileError) as refused:
                imports.decode(root / 'in.wav', root / 'out.wav', threading.Event(), command=[sys.executable, str(failing)])
            self.assertEqual(refused.exception.code, 'invalid_audio')
            self.assertEqual((root / 'out.wav').stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileError) as refused:
                imports.decode(root / 'in.wav', root / 'other.wav', threading.Event(), command=['/nonexistent/ffmpeg'])
            self.assertEqual(refused.exception.code, 'decoder_unavailable')
            with self.assertRaises(FileExistsError):
                imports.decode(root / 'in.wav', root / 'out.wav', threading.Event(), command=[sys.executable, str(failing)])


@unittest.skipUnless(imports.decoder_available(), 'ffmpeg and ffprobe are not installed')
class RealDecoderTests(unittest.TestCase):
    def test_synthetic_wav_aiff_and_m4a_decode_to_sixteen_kilohertz_mono(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y']
            subprocess.run(base + ['-f', 'lavfi', '-i', 'sine=frequency=440:duration=2', '-ar', '44100', '-ac', '2',
                                   str(root / 'a.wav')], check=True, timeout=30, stdin=subprocess.DEVNULL)
            subprocess.run(base + ['-i', str(root / 'a.wav'), str(root / 'a.aiff')], check=True, timeout=30, stdin=subprocess.DEVNULL)
            subprocess.run(base + ['-i', str(root / 'a.wav'), '-c:a', 'aac', str(root / 'a.m4a')], check=True, timeout=30, stdin=subprocess.DEVNULL)
            for name, kind in (('a.wav', 'wav'), ('a.aiff', 'aiff'), ('a.m4a', 'm4a')):
                with self.subTest(name=name):
                    source = root / name
                    before = source.read_bytes()
                    info = imports.probe(source)
                    self.assertEqual(info['format'], kind)
                    self.assertAlmostEqual(info['duration'], 2.0, delta=.2)
                    decoded = root / (name + '.decoded.wav')
                    frames = imports.decode(source, decoded, threading.Event())
                    self.assertAlmostEqual(frames / 16000, 2.0, delta=.2)
                    self.assertEqual(decoded.stat().st_mode & 0o777, 0o600)
                    self.assertEqual(source.read_bytes(), before)
            junk = root / 'junk.wav'
            junk.write_bytes(os.urandom(2048))
            with self.assertRaises(FileError) as refused:
                imports.probe(junk)
            self.assertEqual(refused.exception.code, 'invalid_audio')
            text = root / 'notes.wav'
            text.write_text('not audio at all')
            with self.assertRaises(FileError):
                imports.probe(text)


class ServiceIntegrationTests(unittest.TestCase):
    def test_import_and_dictation_exclude_each_other_over_the_socket(self):
        from test_desktop import Capture, Delivery
        from test_desktop import Engine as TakeEngine
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'talk.wav'
            write_wav(source)
            socket_path = root / 'session.sock'
            engine = TakeEngine()
            engine.transcribe = lambda path, cancelled, seconds=None: TakeEngine.transcribe(engine, path, cancelled)
            session = desktop.Session(Capture(), engine, Delivery(), root / 'recovery')
            files = FileTranscription(engine, root / 'imports', prober=probe_ok, decoder=decoder_frames())
            stopped = threading.Event()
            thread = threading.Thread(target=desktop.serve, args=(socket_path, session, stopped),
                                      kwargs={'lifetime_seconds': 5, 'files': files})
            thread.start()
            try:
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    try:
                        desktop.request(socket_path, 'status')
                        break
                    except (FileNotFoundError, ConnectionRefusedError):
                        time.sleep(.005)
                engine.gate = threading.Event()
                accepted = desktop.request(socket_path, 'import', source=str(source))
                self.assertTrue(accepted['accepted'])
                self.assertTrue(engine.entered.wait(2))
                status = desktop.request(socket_path, 'status')
                self.assertEqual(status['state'], 'idle')
                self.assertEqual(status['file_import']['state'], 'transcribing')
                refused = desktop.request(socket_path, 'start')
                self.assertEqual(refused['error'], 'file_import_active')
                self.assertEqual(session.capture.starts, 0)
                self.assertEqual(desktop.request(socket_path, 'toggle')['error'], 'file_import_active')
                self.assertEqual(desktop.request(socket_path, 'import-status')['state'], 'transcribing')
                engine.gate.set()
                files.wait()
                self.assertEqual(desktop.request(socket_path, 'import-status')['state'], 'finished')
                self.assertEqual(desktop.request(socket_path, 'start')['state'], 'recording')
                busy = desktop.request(socket_path, 'import', source=str(source))
                self.assertEqual((busy['accepted'], busy['error']), (False, 'session_active'))
                desktop.request(socket_path, 'cancel')
                self.assertEqual(desktop.request(socket_path, 'import-forget')['state'], 'idle')
                self.assertEqual(desktop.request(socket_path, 'import', source=None)['error'], 'invalid_audio')
                self.assertEqual(desktop.request(socket_path, 'import-cancel')['state'], 'idle')
                self.assertEqual(desktop.recovery_list(root / 'recovery'), [])
            finally:
                stopped.set()
                thread.join(3)
                files.close()
                session.close()


class CommandLineTests(unittest.TestCase):
    def run_cli(self, *arguments):
        # Bytes, so exact line endings in printed results are observable.
        result = subprocess.run([sys.executable, str(HERE / 'desktop.py'), *arguments],
                                capture_output=True, timeout=30, stdin=subprocess.DEVNULL)
        result.stdout, result.stderr = result.stdout.decode('utf-8'), result.stderr.decode('utf-8')
        return result

    def test_capabilities_are_reported_without_a_service_or_configuration(self):
        result = self.run_cli('--config', '/nonexistent/linux.json', 'capabilities')
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['interface'], 1)
        feature = report['features']['file_transcription']
        self.assertEqual((feature['maximum_seconds'], feature['maximum_bytes']), (600, 512 * 1024 * 1024))
        self.assertEqual(feature['formats'], ['wav', 'aiff', 'm4a'])
        self.assertEqual(report['features']['ai_cleanup']['levels'], ['fast', 'thorough'])
        self.assertEqual(report['features']['cleanup_levels'], ['off', 'basic', 'fast', 'thorough'])
        self.assertEqual(report['features']['pill'], 'frontend')

    def test_result_and_save_work_from_saved_state_without_a_service(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'talk.wav'
            write_wav(source)
            store = root / 'imports'
            store.mkdir(mode=0o700)
            job = store / ('d' * 32)
            job.mkdir(mode=0o700)
            (job / 'transcript.txt').write_text('Hello, 世界\r\nline two', encoding='utf-8', newline='')
            (job / 'source.json').write_text(json.dumps({'source': str(source), 'duration': 1}))
            result = self.run_cli('--imports', str(store), 'import-result')
            self.assertEqual((result.returncode, result.stdout), (0, 'Hello, 世界\r\nline two'))
            refused = self.run_cli('--imports', str(store), 'import-save', str(source), '--overwrite')
            self.assertEqual(refused.returncode, 2)
            self.assertEqual(json.loads(refused.stderr)['error'], 'cannot_replace_source')
            self.assertEqual(source.read_bytes(), source.read_bytes())
            saved = self.run_cli('--imports', str(store), 'import-save', str(root / 'out.txt'))
            self.assertEqual(saved.returncode, 0, saved.stderr)
            self.assertEqual((root / 'out.txt').read_bytes(), 'Hello, 世界\r\nline two'.encode('utf-8'))
            again = self.run_cli('--imports', str(store), 'import-save', str(root / 'out.txt'))
            self.assertEqual(json.loads(again.stderr)['error'], 'destination_exists')
            status = self.run_cli('--runtime', str(root / 'runtime'), 'import-status')
            self.assertEqual(status.returncode, 2)
            self.assertEqual(json.loads(status.stderr)['error'], 'unavailable')


if __name__ == '__main__':
    unittest.main()
