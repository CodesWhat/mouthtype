import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
import time
import unittest

import desktop
import transform
import transform_host

FAKE_WORKER = r'''
import json, os, sys, time
config = json.loads(sys.stdin.readline())['configuration']
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write('start %d %s\n' % (os.getpid(), config['server']))
print(json.dumps({'event': 'ready', 'load_ms': 1}), flush=True)
for line in sys.stdin:
    case = json.loads(line)
    if case['input'] == 'hang':
        time.sleep(60)
    print(json.dumps({'id': case['id'], 'text': 'edited:' + case['input']}), flush=True)
'''


def gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def wait_for(check, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if check():
            return True
        time.sleep(.05)
    return check()


class HostTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir='/tmp', prefix='mt-host-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.runtime = self.root / 'run'
        self.runtime.mkdir(mode=0o700)
        self.worker = self.root / 'fake_worker.py'
        self.worker.write_text(FAKE_WORKER)
        self.log = self.root / 'starts.log'
        os.environ['FAKE_LOG'] = str(self.log)
        self.addCleanup(os.environ.pop, 'FAKE_LOG', None)
        model = self.root / 'model.gguf'
        model.write_bytes(b'model')
        self.settings = {'artifacts': {'model': {'path': str(model), 'sha256': hashlib.sha256(b'model').hexdigest()}},
                         'server': '/bin/fake-server', 'prompt': 'shared'}
        self.addCleanup(transform_host.stop, self.runtime)

    def command(self, idle=30):
        return transform_host.host_command(self.runtime, worker=self.worker, idle=idle, load_seconds=20)

    def ask(self, text, *, idle=30, cancelled=None, settings=None):
        return transform_host.ask(self.runtime, {'settings': settings or self.settings, 'kind': 'fix-grammar',
                                                 'text': text, 'seconds': 10}, cancelled or threading.Event(),
                                  command=self.command(idle), seconds=30)

    def starts(self):
        return [line.split() for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_consecutive_transforms_share_one_server(self):
        self.assertEqual(self.ask('one'), {'text': 'edited:one'})
        self.assertEqual(self.ask('two'), {'text': 'edited:two'})
        self.assertEqual(len(self.starts()), 1)
        self.assertTrue(transform_host.alive(self.runtime))

    def test_idle_timeout_stops_host_and_server(self):
        self.ask('one', idle=1)
        pid = int(self.starts()[0][1])
        self.assertTrue(wait_for(lambda: not transform_host.alive(self.runtime)))
        self.assertTrue(wait_for(lambda: gone(pid)))
        self.assertFalse((self.runtime / transform_host.SOCKET).exists())
        self.assertFalse((self.runtime / transform_host.PIDFILE).exists())
        # The next transform starts a fresh host and server.
        self.assertEqual(self.ask('two', idle=30), {'text': 'edited:two'})
        self.assertEqual(len(self.starts()), 2)

    def test_stop_on_daemon_exit_leaves_no_server(self):
        self.ask('one')
        pid = int(self.starts()[0][1])
        transform_host.stop(self.runtime)
        self.assertFalse(transform_host.alive(self.runtime))
        self.assertTrue(wait_for(lambda: gone(pid)))
        self.assertFalse((self.runtime / transform_host.SOCKET).exists())

    def test_stop_with_no_host_is_a_no_op(self):
        transform_host.stop(self.runtime)

    def test_killing_the_host_still_reaps_the_server(self):
        self.ask('one')
        pid = int(self.starts()[0][1])
        host = int((self.runtime / transform_host.PIDFILE).read_text())
        os.kill(host, 9)
        self.assertTrue(wait_for(lambda: gone(pid)))
        self.assertTrue(wait_for(lambda: not transform_host.alive(self.runtime)))
        self.assertEqual(self.ask('two'), {'text': 'edited:two'})

    def test_cancel_returns_none_and_the_next_request_reloads(self):
        cancelled = threading.Event()
        threading.Timer(.7, cancelled.set).start()
        self.assertIsNone(self.ask('hang', cancelled=cancelled))
        self.assertEqual(self.ask('two'), {'text': 'edited:two'})
        self.assertEqual(len(self.starts()), 2)

    def test_changed_settings_reload_the_server(self):
        self.ask('one')
        self.ask('two', settings={**self.settings, 'server': '/bin/other-server'})
        self.assertEqual([line[2] for line in self.starts()], ['/bin/fake-server', '/bin/other-server'])

    def test_a_second_host_yields_to_the_first(self):
        self.ask('one')
        self.assertEqual(transform_host.serve(self.runtime, worker=self.worker, idle=5, load_seconds=5,
                                              lock_wait=.2), 1)
        self.assertEqual(self.ask('two'), {'text': 'edited:two'})

    def test_invalid_idle_values_use_the_default(self):
        for raw, expected in ((None, 300.0), ('', 300.0), ('x', 300.0), ('-1', 300.0), ('nan', 300.0),
                              ('0', 0.0), ('45', 45.0), ('1e9', 86400.0)):
            env = {} if raw is None else {transform_host.IDLE_VARIABLE: raw}
            self.assertEqual(transform_host.idle_seconds(env), expected, raw)


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(dir='/tmp', prefix='mt-svc-'))
        self.addCleanup(shutil.rmtree, self.root, True)
        self.runtime = self.root / 'run'
        self.worker = self.root / 'fake_worker.py'
        self.worker.write_text(FAKE_WORKER)
        os.environ['FAKE_LOG'] = str(self.root / 'starts.log')
        self.addCleanup(os.environ.pop, 'FAKE_LOG', None)
        model = self.root / 'model.gguf'
        model.write_bytes(b'model')
        self.settings = {'artifacts': {'model': {'path': str(model), 'sha256': hashlib.sha256(b'model').hexdigest()}},
                         'server': '/bin/fake-server', 'prompt': 'shared'}
        self.addCleanup(transform_host.stop, self.runtime)

    def service(self, idle):
        return transform.TransformService(self.root / 'linux.json', self.runtime, worker=self.worker,
                                          idle_seconds=idle, load_seconds=20)

    def starts(self):
        log = self.root / 'starts.log'
        return len(log.read_text().splitlines()) if log.exists() else 0

    def test_resident_transforms_reuse_the_server(self):
        service = self.service(30)
        self.assertEqual(service._model('fix-grammar', 'a b', self.settings), 'edited:a b')
        self.assertEqual(service._model('make-shorter', 'c d', self.settings), 'edited:c d')
        self.assertEqual(self.starts(), 1)

    def test_idle_zero_keeps_the_per_run_server(self):
        service = self.service(0)
        self.assertEqual(service._model('fix-grammar', 'a b', self.settings), 'edited:a b')
        self.assertEqual(service._model('fix-grammar', 'c d', self.settings), 'edited:c d')
        self.assertEqual(self.starts(), 2)
        self.assertFalse(transform_host.alive(self.runtime))

    def test_hash_cache_is_used_by_the_per_run_engine(self):
        from proof import VerifiedHashes
        cache = VerifiedHashes(self.root / 'state' / 'verified.json')
        service = transform.TransformService(self.root / 'linux.json', self.runtime, worker=self.worker,
                                             idle_seconds=0, load_seconds=20, hash_cache=cache)
        service._model('fix-grammar', 'a', self.settings)
        self.assertTrue((self.root / 'state' / 'verified.json').exists())


class SpeechWarmTests(unittest.TestCase):
    def test_warm_loads_before_the_first_take_and_reuses_the_worker(self):
        root = Path(tempfile.mkdtemp(dir='/tmp', prefix='mt-warm-'))
        self.addCleanup(shutil.rmtree, root, True)
        script = root / 'speech.py'
        script.write_text(
            "import json,os,sys\nsys.stdin.readline()\n"
            "open(os.environ['FAKE_LOG'],'a').write('start\\n')\n"
            "print(json.dumps({'event':'ready'}),flush=True)\n"
            "for line in sys.stdin:\n c=json.loads(line)\n print(json.dumps({'id':c['id'],'text':'hi'}),flush=True)\n")
        os.environ['FAKE_LOG'] = str(root / 'log')
        self.addCleanup(os.environ.pop, 'FAKE_LOG', None)
        engine = desktop.SpeechEngine({'artifacts': {}}, worker=script)
        self.addCleanup(engine.stop)
        engine.warm().join(15)
        self.assertIsNotNone(engine.worker)
        self.assertEqual(engine.transcribe(root / 'x.wav', threading.Event()), 'hi')
        self.assertEqual((root / 'log').read_text().split(), ['start'])

    def test_failed_warm_leaves_the_engine_cold_and_the_take_reports_its_own_error(self):
        engine = desktop.SpeechEngine({'artifacts': {'m': {'path': '/nonexistent', 'sha256': '0' * 64}}})
        engine.warm().join(15)
        self.assertIsNone(engine.worker)
        with self.assertRaises(RuntimeError):
            engine.transcribe('x.wav', threading.Event())


if __name__ == '__main__':
    unittest.main()
