import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/restore-public-assets.py'
spec = importlib.util.spec_from_file_location('restore_public_assets', SCRIPT)
restore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restore)


def asset(name, data):
    return {'name': name, 'state': 'uploaded', 'size': len(data),
            'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}


class RestoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mouthtype-restore-test-')
        self.addCleanup(temporary.cleanup)
        self.public = Path(temporary.name) / 'public'
        self.files = {
            'Mouthtype-1.0.0-macos-arm64.zip': b'zip',
            'Mouthtype-1.0.0-macos-arm64.dmg': b'dmg',
            'Mouthtype-1.0.0-source.tar.gz': b'src',
            'Mouthtype-1.0.0-macos-arm64.zip.sha256': b'sum',
            'release-manifest.json': b'{}',
            'Mouthtype-1.0.0-sbom.cdx.json': b'sbom',
            'Mouthtype-1.0.0-macos-arm64.zip.sigstore.json': b'sig',
        }
        self.releases = [{'tag_name': 'v1.0.0', 'draft': False,
                          'assets': [asset(n, d) for n, d in self.files.items()]}]

    def download(self, tag, name, destination):
        destination.write_bytes(self.files[name])

    def test_only_retained_files_are_restored_under_the_version_directory(self):
        done = restore.restore(self.releases, self.public, self.download)
        self.assertEqual(done, ['1.0.0'])
        names = sorted(p.name for p in (self.public / 'releases/1.0.0').iterdir())
        self.assertEqual(names, sorted(n for n in self.files
                                       if 'sbom' not in n and 'sigstore' not in n))

    def test_digest_mismatch_blocks_and_leaves_nothing_behind(self):
        self.files['Mouthtype-1.0.0-macos-arm64.dmg'] = b'tampered'
        self.releases[0]['assets'][1]['digest'] = 'sha256:' + '0' * 64
        with self.assertRaises(RuntimeError):
            restore.restore(self.releases, self.public, self.download)
        self.assertFalse((self.public / 'releases/1.0.0').exists())

    def test_existing_identical_files_are_kept_and_different_ones_refused(self):
        restore.restore(self.releases, self.public, self.download)
        restore.restore(self.releases, self.public, self.download)
        (self.public / 'releases/1.0.0/Mouthtype-1.0.0-macos-arm64.zip').write_bytes(b'other')
        with self.assertRaises(RuntimeError):
            restore.restore(self.releases, self.public, self.download)

    def test_drafts_and_unselected_versions_are_skipped(self):
        self.releases[0]['draft'] = True
        self.assertEqual(restore.restore(self.releases, self.public, self.download), [])
        self.releases[0]['draft'] = False
        self.assertEqual(restore.restore(self.releases, self.public, self.download, ['2.0.0']), [])


if __name__ == '__main__':
    unittest.main()
