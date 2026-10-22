import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import setup_cleanup
from setup_progress import DownloadProgress


@unittest.skipUnless(sys.platform == 'linux' and platform.machine() in ('x86_64', 'AMD64'),
                     'cleanup setup pins Linux x86_64 artifacts')
class SetupCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.server = self.root / 'llama-server'
        self.server.write_text('#!/bin/sh\necho "version: 1 (commit 6420cf5dd)"\n')
        self.server.chmod(0o755)
        self.weights = {'fast': b'fast model bytes', 'thorough': b'thorough model bytes'}
        self.pins = {
            'llama': {'revision': '6420cf5dd588c68e48657a0bbd82bb3bd5ac7209', 'license': 'MIT'},
            's1': {'source': 'https://example.invalid/s1.gguf', 'sha256': hashlib.sha256(self.weights['fast']).hexdigest(), 'license': 'Apache-2.0'},
            'qwen3_4b': {'source': 'https://example.invalid/qwen.gguf', 'sha256': hashlib.sha256(self.weights['thorough']).hexdigest(), 'license': 'Apache-2.0'},
        }
        self.downloads = []

    def download(self, url, destination, progress=None):
        self.downloads.append(url)
        partial = destination.with_suffix(destination.suffix + '.part')
        partial.write_bytes(self.weights['fast'] if 's1' in url else self.weights['thorough'])
        return partial

    def test_fast_setup_verifies_and_writes_config_without_touching_linux_json(self):
        destination = self.root / 'cleanup'
        path = setup_cleanup.setup(destination, ['fast'], server=self.server, pins=self.pins, download_fn=self.download,
                                   check_fn=lambda server: 'fake runtime', threads=4)
        config = json.loads(path.read_text())
        engine = config['engines']['fast']
        self.assertEqual(engine['prompt'], 's1')
        self.assertEqual(engine['threads'], 4)
        self.assertEqual(engine['artifacts']['model']['sha256'], self.pins['s1']['sha256'])
        self.assertEqual((destination / 's1-mini-q4_k_m.gguf').read_bytes(), self.weights['fast'])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads((destination / 'cleanup-setup.json').read_text())['state'], 'ready')
        self.assertFalse((destination / 'linux.json').exists())
        self.assertEqual(self.downloads, [self.pins['s1']['source']])

    def test_thorough_adds_to_existing_config_and_skips_a_verified_download(self):
        destination = self.root / 'cleanup'
        setup_cleanup.setup(destination, ['fast'], server=self.server, pins=self.pins, download_fn=self.download,
                            check_fn=lambda server: 'fake runtime')
        path = setup_cleanup.setup(destination, ['fast', 'thorough'], server=self.server, pins=self.pins,
                                   download_fn=self.download, check_fn=lambda server: 'fake runtime')
        config = json.loads(path.read_text())
        self.assertEqual(sorted(config['engines']), ['fast', 'thorough'])
        self.assertEqual(config['engines']['thorough']['prompt'], 'shared')
        self.assertEqual(self.downloads, [self.pins['s1']['source'], self.pins['qwen3_4b']['source']])

    def test_hash_mismatch_removes_partial_and_records_failure(self):
        destination = self.root / 'cleanup'
        def wrong(url, dest):
            partial = dest.with_suffix(dest.suffix + '.part')
            partial.write_bytes(b'tampered')
            return partial
        with self.assertRaises(ValueError):
            setup_cleanup.setup(destination, ['fast'], server=self.server, pins=self.pins, download_fn=wrong,
                                check_fn=lambda server: 'fake runtime')
        self.assertFalse(list(destination.glob('*.gguf*')))
        self.assertEqual(json.loads((destination / 'cleanup-setup.json').read_text())['state'], 'failed')
        self.assertFalse((destination / 'cleanup.json').exists())

    def test_server_revision_is_checked(self):
        with self.assertRaises(ValueError):
            setup_cleanup.check_server(self.server, revision='abcdef0123456789abcdef0123456789abcdef01')
        self.assertIn('6420cf5dd', setup_cleanup.check_server(self.server, revision=self.pins['llama']['revision']))

    def test_bounded_run_stops_a_hung_child(self):
        with self.assertRaises(TimeoutError):
            setup_cleanup.bounded_run(['sleep', '30'], .2)

    def test_cli_refuses_without_required_helpers_and_prints_config_hint(self):
        import subprocess, sys
        result = subprocess.run([sys.executable, str(Path(setup_cleanup.__file__)), '--destination', str(self.root / 'x'),
                                 '--server', str(self.server)], capture_output=True, text=True, timeout=60,
                                env={**os.environ, 'PATH': '/nonexistent'})
        self.assertEqual(result.returncode, 2)
        self.assertIn('Missing required helper', result.stderr)


if __name__ == '__main__':
    unittest.main()


class SlowHandler(BaseHTTPRequestHandler):
    body = b'x' * 60000

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', str(len(self.body)))
        self.end_headers()
        for start in range(0, len(self.body), 20000):
            self.wfile.write(self.body[start:start + 20000])
            self.wfile.flush()
            time.sleep(0.8)

    def log_message(self, *args):
        pass


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_tracker_is_throttled_monotonic_and_capped(self):
        now = [0.0]
        seen = []
        tracker = DownloadProgress(100, lambda done, total: seen.append((done, total)), clock=lambda: now[0])
        for tick, done in [(0, 0), (0.1, 10), (0.3, 20), (0.6, 30), (0.7, 25), (1.2, 500)]:
            now[0] = tick
            tracker(done)
        tracker.finish()
        self.assertEqual(seen, [(0, 100), (30, 100), (100, 100)])
        self.assertTrue(all(a[0] <= b[0] and b[0] <= b[1] for a, b in zip(seen, seen[1:])))

    def test_setup_writes_bytes_done_and_total_from_download_progress(self):
        weights = b'w' * 1000
        pins = {'llama': {'revision': '6420cf5dd588c68e48657a0bbd82bb3bd5ac7209'},
                's1': {'source': 'https://example.invalid/s1', 'sha256': hashlib.sha256(weights).hexdigest(), 'bytes': 1000}}
        server = self.root / 'llama-server'
        server.write_text('#!/bin/sh\n')
        server.chmod(0o755)
        destination = self.root / 'cleanup'
        status = destination / 'cleanup-setup.json'
        states = []

        def download(url, target, progress=None):
            partial = target.with_suffix(target.suffix + '.part')
            partial.write_bytes(weights)
            for done in (100, 400, 400, 900):
                progress(done)
                states.append(json.loads(status.read_text()))
            return partial

        original = setup_cleanup.DownloadProgress
        setup_cleanup.DownloadProgress = lambda total, emit: original(total, emit, interval=0)
        self.addCleanup(setattr, setup_cleanup, 'DownloadProgress', original)
        setup_cleanup.setup(destination, ['fast'], server=server, pins=pins, download_fn=download,
                            check_fn=lambda found: 'fake runtime')
        done = [state['bytes_done'] for state in states]
        self.assertEqual(done, sorted(done))
        self.assertEqual(done, [100, 400, 400, 900])
        self.assertTrue(all(s['state'] == 'downloading' and s['bytes_total'] == 1000 and s['bytes_done'] <= 1000 for s in states))
        self.assertEqual(json.loads(status.read_text())['state'], 'ready')

    @unittest.skipUnless(shutil.which('curl'), 'curl is needed for the local download fixture')
    def test_real_download_reports_growing_bytes_from_a_local_server(self):
        server = ThreadingHTTPServer(('127.0.0.1', 0), SlowHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 5)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        seen = []
        partial = setup_cleanup.download('http://127.0.0.1:%d/m' % server.server_port, self.root / 'm.gguf',
                                         seconds=30, progress=seen.append)
        self.assertEqual(partial.stat().st_size, 60000)
        self.assertGreaterEqual(len(seen), 2)
        self.assertEqual(seen, sorted(seen))
        self.assertTrue(all(0 <= size <= 60000 for size in seen))
