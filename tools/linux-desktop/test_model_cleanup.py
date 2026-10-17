import json
from pathlib import Path
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
 time.sleep(10)
''')
        engine = CleanupEngine(settings, worker=script)
        self.addCleanup(engine.close)
        with self.assertRaises(RuntimeError):
            engine.clean('hello there', threading.Event(), seconds=.05)
        self.assertIsNone(engine.worker)
        self.assertEqual(engine.state, 'idle')

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


if __name__ == '__main__':
    unittest.main()
