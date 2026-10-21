import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

import proof
import worker


class Clock:
    def __init__(self):
        self.now = 1000000.0

    def __call__(self):
        return self.now


class HashCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.model = self.root / 'model.bin'
        self.model.write_bytes(b'weights')
        self.config = {'artifacts': {'model': {'path': str(self.model),
                                               'sha256': hashlib.sha256(b'weights').hexdigest()}}}
        self.clock = Clock()
        self.cache_path = self.root / 'state' / 'verified.json'
        self.cache = proof.VerifiedHashes(self.cache_path, clock=self.clock)
        self.hashed = []
        real = proof.digest

        def counting(path):
            self.hashed.append(path)
            return real(path)
        patcher = mock.patch.object(proof, 'digest', counting)
        patcher.start()
        self.addCleanup(patcher.stop)

    def verify(self, cache=None):
        return proof.verify_artifacts(self.config, cache or self.cache)

    def test_first_load_hashes_and_second_skips(self):
        self.assertEqual(self.verify(), {'model': self.config['artifacts']['model']['sha256']})
        self.assertEqual(len(self.hashed), 1)
        self.assertEqual(self.verify(), {'model': self.config['artifacts']['model']['sha256']})
        self.assertEqual(len(self.hashed), 1)

    def test_cache_file_is_private_and_holds_the_stat_fields(self):
        self.verify()
        self.assertEqual(stat.S_IMODE(self.cache_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.cache_path.parent.stat().st_mode), 0o700)
        entry = json.loads(self.cache_path.read_text())['entries'][os.path.realpath(self.model)]
        self.assertEqual(set(entry), {'size', 'mtime_ns', 'ino', 'dev', 'ctime_ns', 'sha256', 'verified_at'})
        self.assertEqual([p.name for p in self.cache_path.parent.iterdir()], ['verified.json'])

    def test_any_changed_stat_field_rehashes(self):
        self.verify()
        real = proof.VerifiedHashes.fingerprint
        for field in ('size', 'mtime_ns', 'ino', 'dev', 'ctime_ns'):
            with self.subTest(field=field):
                before = len(self.hashed)

                def changed(path, field=field):
                    path, values = real(path)
                    return path, {**values, field: values[field] + 1}
                with mock.patch.object(proof.VerifiedHashes, 'fingerprint', staticmethod(changed)):
                    self.verify()
                self.assertEqual(len(self.hashed), before + 1)

    def test_a_real_edit_with_the_same_digest_still_rehashes(self):
        self.verify()
        os.utime(self.model, ns=(1, 1))
        self.verify()
        self.assertEqual(len(self.hashed), 2)

    def test_a_replaced_file_fails_verification_and_drops_the_entry(self):
        self.verify()
        self.model.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch for model'):
            self.verify()
        self.assertEqual(json.loads(self.cache_path.read_text())['entries'], {})

    def test_full_reverify_at_least_daily(self):
        self.verify()
        self.clock.now += proof.VerifiedHashes.INTERVAL_SECONDS - 1
        self.verify()
        self.assertEqual(len(self.hashed), 1)
        self.clock.now += 1
        self.verify()
        self.assertEqual(len(self.hashed), 2)
        self.verify()
        self.assertEqual(len(self.hashed), 2)

    def test_clock_going_backwards_is_not_trusted(self):
        self.verify()
        self.clock.now -= 5
        self.verify()
        self.assertEqual(len(self.hashed), 2)

    def test_force_switch_always_hashes(self):
        forced = proof.VerifiedHashes(self.cache_path, force=True, clock=self.clock)
        self.verify(forced)
        self.verify(forced)
        self.assertEqual(len(self.hashed), 2)

    def test_corrupt_or_unwritable_cache_falls_back_to_hashing(self):
        self.cache_path.parent.mkdir(parents=True)
        for content in (b'{not json', b'[]', json.dumps({'version': 1, 'entries': {'x': 3}}).encode()):
            self.cache_path.write_bytes(content)
            before = len(self.hashed)
            self.verify()
            self.assertEqual(len(self.hashed), before + 1)
            self.cache_path.unlink()
        blocked = proof.VerifiedHashes(self.root / 'model.bin' / 'nested' / 'cache.json', clock=self.clock)
        before = len(self.hashed)
        self.assertIn('model', self.verify(blocked))
        self.assertEqual(len(self.hashed), before + 1)

    def test_an_entry_for_a_different_expected_digest_is_not_reused(self):
        self.verify()
        other = {'artifacts': {'model': {**self.config['artifacts']['model'], 'sha256': '0' * 64}}}
        with self.assertRaises(ValueError):
            proof.verify_artifacts(other, self.cache)

    def test_without_a_cache_every_call_hashes(self):
        proof.verify_artifacts(self.config)
        proof.verify_artifacts(self.config)
        self.assertEqual(len(self.hashed), 2)


class VersionProbeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.log = self.root / 'probes'
        self.server = self.root / 'llama-server'
        self.write_server('version: 1 (6420cf5)')
        self.config = {'server': str(self.server), 'version_cache': str(self.root / 'version.json')}

    def write_server(self, text):
        self.server.write_text('#!/bin/sh\necho probed >> %s\necho "%s"\n' % (self.log, text))
        self.server.chmod(0o755)

    def probes(self):
        return len(self.log.read_text().split()) if self.log.exists() else 0

    def test_probe_runs_once_while_the_binary_is_unchanged(self):
        self.assertIn('6420cf5', worker.server_description(self.config))
        self.assertIn('6420cf5', worker.server_description(self.config))
        self.assertEqual(self.probes(), 1)
        self.assertEqual(stat.S_IMODE(Path(self.config['version_cache']).stat().st_mode), 0o600)

    def test_probe_reruns_when_the_binary_changes(self):
        worker.server_description(self.config)
        self.write_server('version: 2 (abcdef0)')
        os.utime(self.server, ns=(5, 5))
        self.assertIn('abcdef0', worker.server_description(self.config))
        self.assertEqual(self.probes(), 2)

    def test_no_cache_setting_probes_every_time(self):
        config = {'server': self.config['server']}
        worker.server_description(config)
        worker.server_description(config)
        self.assertEqual(self.probes(), 2)

    def test_corrupt_cache_falls_back_to_the_probe(self):
        Path(self.config['version_cache']).write_text('nope')
        self.assertIn('6420cf5', worker.server_description(self.config))
        self.assertEqual(self.probes(), 1)


if __name__ == '__main__':
    unittest.main()
