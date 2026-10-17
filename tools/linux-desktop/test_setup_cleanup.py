import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

import setup_cleanup


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

    def download(self, url, destination):
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
