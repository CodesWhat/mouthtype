import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import desktop
from desktop import CleanupEngine, Session
from test_desktop import Capture, Delivery, Engine


class FakeCleanup:
    def __init__(self, text=None, *, timeout=False, fail=False, delay=0):
        self.text, self.timeout, self.fail, self.delay = text, timeout, fail, delay
        self.calls = []
        self.state, self.error, self.load_ms = 'ready', None, 12

    def status(self):
        return {'state': self.state, 'error': self.error, 'load_ms': self.load_ms, 'prompt': 's1'}

    def clean(self, text, cancelled, *, seconds, controls=None):
        self.calls.append((text, seconds))
        end = time.monotonic() + self.delay
        while time.monotonic() < end:
            if cancelled.is_set():
                raise RuntimeError('Cleanup engine unavailable')
            time.sleep(.005)
        if self.fail:
            raise RuntimeError('Cleanup engine unavailable')
        if self.timeout:
            return None
        return self.text if self.text is not None else text

    def close(self):
        pass


class ModelCleanupSessionTests(unittest.TestCase):
    def run_take(self, cleanup, level='fast', raw='um so we should ship it comma right'):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        session = Session(Capture(), Engine(raw), Delivery(), Path(temp.name), cleanup=level, cleanup_engine=cleanup)
        self.addCleanup(session.close)
        session.command('start')
        session.command('stop')
        session.wait()
        take = session.take
        return session, take

    def test_accepted_model_text_replaces_basic_and_raw_is_preserved(self):
        cleanup = FakeCleanup('So we should ship it, right?')
        session, take = self.run_take(cleanup)
        self.assertEqual((take / 'transcript.txt').read_text(), 'So we should ship it, right?')
        self.assertEqual((take / 'raw-recognition.txt').read_text(), 'um so we should ship it comma right')
        record = json.loads((take / 'cleanup.json').read_text())
        self.assertEqual((record['level'], record['outcome']), ('fast', 'ok'))
        self.assertEqual((take / 'cleanup.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(cleanup.calls[0][0], 'Um so we should ship it, right')
        self.assertAlmostEqual(cleanup.calls[0][1], 1.0 + 0.035 * 7)
        status = session.command('status')
        self.assertEqual(status['cleanup']['last_outcome'], 'ok')
        self.assertEqual(status['cleanup']['model']['state'], 'ready')
        self.assertNotIn('ship', json.dumps(status))

    def test_forgetting_a_model_cleaned_take_leaves_no_directory(self):
        session, take = self.run_take(FakeCleanup('So we should ship it, right?'))
        self.assertTrue((take / 'cleanup.json').is_file())
        runtime = tempfile.TemporaryDirectory()
        self.addCleanup(runtime.cleanup)
        result = subprocess.run([sys.executable, str(Path(desktop.__file__)), '--recovery', str(session.recovery),
                                 '--runtime', runtime.name, 'forget', take.name],
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(take.exists())

    def test_timeout_failure_and_guard_rejection_fall_back_to_basic(self):
        for cleanup, outcome in ((FakeCleanup(timeout=True), 'timeout'), (FakeCleanup(fail=True), 'failed'),
                                 (FakeCleanup('Certainly, I will do that for you today.'), 'guard-rejected')):
            with self.subTest(outcome=outcome):
                session, take = self.run_take(cleanup)
                self.assertEqual((take / 'transcript.txt').read_text(), 'Um so we should ship it, right')
                self.assertEqual(json.loads((take / 'cleanup.json').read_text())['outcome'], outcome)
                self.assertEqual(session.command('status')['cleanup']['last_outcome'], outcome)

    def test_short_takes_skip_the_model_and_off_basic_never_call_it(self):
        cleanup = FakeCleanup('Yes.')
        session, take = self.run_take(cleanup, raw='yes')
        self.assertEqual(cleanup.calls, [])
        self.assertEqual(json.loads((take / 'cleanup.json').read_text())['outcome'], 'skipped')
        for level in ('off', 'basic'):
            cleanup = FakeCleanup('changed')
            session, take = self.run_take(cleanup, level=level)
            self.assertEqual(cleanup.calls, [])
            self.assertFalse((take / 'cleanup.json').exists())

    def test_cancel_during_model_cleanup_publishes_nothing(self):
        cleanup = FakeCleanup('late text', delay=5)
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        session = Session(Capture(), Engine(), Delivery(), Path(temp.name), cleanup='fast', cleanup_engine=cleanup)
        self.addCleanup(session.close)
        session.command('start')
        session.command('stop')
        deadline = time.monotonic() + 2
        while not cleanup.calls and time.monotonic() < deadline:
            time.sleep(.005)
        session.command('cancel')
        session.wait()
        self.assertFalse(list(Path(temp.name).glob('*/transcript.txt')))
        self.assertEqual(session.state, 'idle')

    def test_configuration_requires_engine_path_for_model_levels(self):
        from desktop import validate_config
        base = {'engine_config': '/local/engines.json'}
        validate_config({**base, 'cleanup': 'fast', 'cleanup_engine': 'cleanup.json'})
        for change in ({'cleanup': 'fast'}, {'cleanup': 'thorough'}, {'cleanup': 'smart'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                validate_config({**base, **change})


class CleanupEngineTests(unittest.TestCase):
    def worker(self, body):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = Path(temp.name) / 'worker.py'
        path.write_text('import json,sys,time\nconfig=json.loads(sys.stdin.readline())\n' + body)
        model = Path(temp.name) / 'model.gguf'
        model.write_bytes(b'weights')
        import hashlib
        settings = {'server': '/fake/llama-server', 'prompt': 's1', 'artifacts': {
            'model': {'path': str(model), 'sha256': hashlib.sha256(b'weights').hexdigest()}}}
        return settings, path

    def test_resident_engine_reuses_its_worker_and_reports_timeouts_without_reload(self):
        settings, script = self.worker('''print(json.dumps({'event':'ready'}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 if r['input']=='slow': print(json.dumps({'id':r['id'],'event':'timeout'}),flush=True)
 else: print(json.dumps({'id':r['id'],'text':r['input'].upper()}),flush=True)
''')
        engine = CleanupEngine(settings, worker=script)
        self.addCleanup(engine.close)
        self.assertEqual(engine.state, 'idle')
        engine.warm().join(5)
        self.assertEqual(engine.state, 'ready')
        self.assertIsInstance(engine.load_ms, int)
        pid = engine.worker.process.pid
        self.assertEqual(engine.clean('hello there', threading.Event(), seconds=2), 'HELLO THERE')
        self.assertIsNone(engine.clean('slow', threading.Event(), seconds=2))
        self.assertEqual(engine.worker.process.pid, pid)
        self.assertEqual(engine.status()['state'], 'ready')
        engine.close()
        self.assertEqual(engine.state, 'idle')

    def test_hung_worker_is_reaped_and_engine_recovers_on_next_request(self):
        settings, script = self.worker('''print(json.dumps({'event':'ready'}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 if r['input']=='Warm up, please.': print(json.dumps({'id':r['id'],'text':'ok'}),flush=True)
 else: time.sleep(10)
''')
        engine = CleanupEngine(settings, worker=script)
        self.addCleanup(engine.close)
        engine.warm().join(5)
        with self.assertRaises(RuntimeError):
            engine.clean('hello there', threading.Event(), seconds=.05)
        self.assertIsNone(engine.worker)
        self.assertEqual(engine.state, 'idle')

    def test_cold_engine_returns_none_at_once_and_warms_in_the_background(self):
        settings, script = self.worker('''time.sleep(.5)
print(json.dumps({'event':'ready'}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 print(json.dumps({'id':r['id'],'text':r['input'].upper()}),flush=True)
''')
        engine = CleanupEngine(settings, worker=script)
        self.addCleanup(engine.close)
        started = time.monotonic()
        self.assertIsNone(engine.clean('hello there', threading.Event(), seconds=2))
        self.assertLess(time.monotonic() - started, .3)
        thread = engine.warming
        self.assertIsNotNone(thread)
        self.assertIs(engine.warm(), thread)
        thread.join(5)
        self.assertEqual(engine.state, 'ready')
        self.assertEqual(engine.clean('hello there', threading.Event(), seconds=2), 'HELLO THERE')

    def test_close_stops_a_load_in_progress(self):
        settings, script = self.worker('''time.sleep(30)
print(json.dumps({'event':'ready'}),flush=True)
''')
        engine = CleanupEngine(settings, worker=script, startup_seconds=300)
        thread = engine.warm()
        deadline = time.monotonic() + 2
        while engine.state != 'loading' and time.monotonic() < deadline:
            time.sleep(.01)
        started = time.monotonic()
        engine.close()
        thread.join(2)
        self.assertLess(time.monotonic() - started, 2)
        self.assertFalse(thread.is_alive())
        self.assertIsNone(engine.worker)

    def test_clean_gives_up_waiting_for_a_busy_engine_within_its_budget(self):
        settings, script = self.worker('''print(json.dumps({'event':'ready'}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 print(json.dumps({'id':r['id'],'text':'x'}),flush=True)
''')
        engine = CleanupEngine(settings, worker=script)
        self.addCleanup(engine.close)
        engine.warm().join(5)
        self.assertEqual(engine.state, 'ready')
        with engine.lock:
            started = time.monotonic()
            self.assertIsNone(engine.clean('hello there', threading.Event(), seconds=.2))
            self.assertLess(time.monotonic() - started, 1)
            cancelled = threading.Event()
            cancelled.set()
            self.assertIsNone(engine.clean('hello there', cancelled, seconds=30))

    def test_missing_weights_report_absent_and_bad_settings_are_rejected(self):
        settings, script = self.worker('print(json.dumps({"event":"ready"}),flush=True)\n')
        Path(settings['artifacts']['model']['path']).unlink()
        self.assertEqual(CleanupEngine(settings, worker=script).state, 'absent')
        for bad in ({}, {'server': 1, 'artifacts': {}}, {**settings, 'prompt': 'other'},
                    {**settings, 'artifacts': {'model': {'path': 'x', 'sha256': 'short'}}}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                CleanupEngine(bad, worker=script)

    def test_startup_failure_is_reported_as_failed(self):
        settings, script = self.worker('print(json.dumps({"event":"error","error_class":"ValueError"}),flush=True)\nsys.exit(1)\n')
        engine = CleanupEngine(settings, worker=script)
        self.addCleanup(engine.close)
        engine.warm().join(5)
        self.assertEqual((engine.state, engine.error), ('failed', 'ValueError'))

    def test_failed_load_retries_with_backoff_and_recovers(self):
        settings, script = self.worker('')
        flag = Path(script).parent / 'attempted'
        script.write_text('import json,sys,time,os\nconfig=json.loads(sys.stdin.readline())\n'
                          'flag=%r\n'
                          'if not os.path.exists(flag):\n open(flag,"w").close()\n'
                          ' print(json.dumps({"event":"error","error_class":"ValueError"}),flush=True)\n sys.exit(1)\n'
                          'print(json.dumps({"event":"ready"}),flush=True)\n'
                          'for line in sys.stdin:\n r=json.loads(line)\n'
                          ' print(json.dumps({"id":r["id"],"text":r["input"].upper()}),flush=True)\n' % str(flag))
        now = [1000.0]
        engine = CleanupEngine(settings, worker=script, clock=lambda: now[0])
        self.addCleanup(engine.close)
        engine.warm().join(5)
        self.assertEqual(engine.state, 'failed')
        # Before the 30 s backoff elapses a take does not start another load.
        now[0] += 29
        self.assertIsNone(engine.clean('hello', threading.Event(), seconds=2))
        self.assertEqual(engine.state, 'failed')
        now[0] += 2
        started = time.monotonic()
        self.assertIsNone(engine.clean('hello', threading.Event(), seconds=2))
        self.assertLess(time.monotonic() - started, .3)
        engine.warming.join(5)
        self.assertEqual(engine.state, 'ready')
        self.assertEqual((engine.failures, engine.retry_at), (0, 0.0))
        self.assertEqual(engine.clean('hello', threading.Event(), seconds=2), 'HELLO')

    def test_retry_delay_grows_and_is_capped(self):
        settings, script = self.worker('print(json.dumps({"event":"error","error_class":"ValueError"}),flush=True)\nsys.exit(1)\n')
        now = [0.0]
        engine = CleanupEngine(settings, worker=script, clock=lambda: now[0])
        self.addCleanup(engine.close)
        delays = []
        for _ in range(6):
            engine.warm().join(5)
            self.assertEqual(engine.state, 'failed')
            delays.append(engine.retry_at - now[0])
            now[0] = engine.retry_at
            engine.clean('x', threading.Event(), seconds=1)
        self.assertEqual(delays, [30, 120, 480, 1800, 1800, 1800])

    def test_artifacts_restored_while_absent_are_picked_up_without_a_restart(self):
        settings, script = self.worker('''print(json.dumps({'event':'ready'}),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 print(json.dumps({'id':r['id'],'text':r['input'].upper()}),flush=True)
''')
        model = Path(settings['artifacts']['model']['path'])
        weights = model.read_bytes()
        model.unlink()
        now = [50.0]
        engine = CleanupEngine(settings, worker=script, clock=lambda: now[0])
        self.addCleanup(engine.close)
        self.assertEqual(engine.state, 'absent')
        model.write_bytes(weights)
        # Rechecked at most once per 30 s.
        now[0] += 10
        self.assertIsNone(engine.clean('hello', threading.Event(), seconds=2))
        self.assertEqual(engine.state, 'absent')
        self.assertIsNone(engine.warming)
        now[0] += 25
        self.assertIsNone(engine.clean('hello', threading.Event(), seconds=2))
        engine.warming.join(5)
        self.assertEqual(engine.state, 'ready')
        self.assertEqual(engine.clean('hello', threading.Event(), seconds=2), 'HELLO')

    def test_absent_engine_with_still_missing_artifacts_stays_absent(self):
        settings, script = self.worker('print(json.dumps({"event":"ready"}),flush=True)\n')
        Path(settings['artifacts']['model']['path']).unlink()
        now = [0.0]
        engine = CleanupEngine(settings, worker=script, clock=lambda: now[0])
        now[0] += 31
        self.assertIsNone(engine.clean('hello', threading.Event(), seconds=2))
        self.assertEqual(engine.state, 'absent')
        self.assertIsNone(engine.warming)


if __name__ == '__main__':
    unittest.main()
