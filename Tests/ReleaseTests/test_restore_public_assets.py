import hashlib
import json
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/restore-public-assets.py'
spec = importlib.util.spec_from_file_location('restore_public_assets', SCRIPT)
restore = importlib.util.module_from_spec(spec)
spec.loader.exec_module(restore)

STAGE = Path(__file__).resolve().parents[2] / 'scripts/stage-public-release.py'
stage_spec = importlib.util.spec_from_file_location('stage_public_release', STAGE)
stage = importlib.util.module_from_spec(stage_spec)
stage_spec.loader.exec_module(stage)


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
        retained = [n for n in self.files if 'sbom' not in n and 'sigstore' not in n]
        # The source checksum is derived when the release doesn't carry it.
        self.assertEqual(names, sorted(retained + ['Mouthtype-1.0.0-source.tar.gz.sha256']))

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


class RestoredTreeValidationTests(unittest.TestCase):
    """Feed a restored tree through the same checks publish-website.py runs."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mouthtype-restore-test-')
        self.addCleanup(temporary.cleanup)
        self.public = Path(temporary.name) / 'public'
        sha = lambda data: hashlib.sha256(data).hexdigest()
        zip_, dmg = b'zip', b'dmg'
        manifest = {'version': '1.0.0', 'build': '1', 'notarizationStatus': 'Accepted',
                    'signatureVerified': True, 'stapleVerified': True,
                    'extractedGatekeeperAccepted': True,
                    'archive': 'Mouthtype-1.0.0-macos-arm64.zip', 'archiveSHA256': sha(zip_),
                    'archiveBytes': len(zip_), 'dmg': 'Mouthtype-1.0.0-macos-arm64.dmg',
                    'dmgNotarizationStatus': 'Accepted', 'dmgSignatureVerified': True,
                    'dmgStapleVerified': True, 'dmgGatekeeperAccepted': True,
                    'dmgSHA256': sha(dmg), 'dmgBytes': len(dmg)}
        self.files = {'Mouthtype-1.0.0-macos-arm64.zip': zip_, 'Mouthtype-1.0.0-macos-arm64.dmg': dmg,
                      'Mouthtype-1.0.0-source.tar.gz': b'src',
                      'release-manifest.json': json.dumps(manifest).encode()}
        self.releases = [{'tag_name': 'v1.0.0', 'draft': False,
                          'assets': [asset(n, d) for n, d in self.files.items()]}]

    def download(self, tag, name, destination):
        destination.write_bytes(self.files[name])

    def check(self):
        directory = self.public / 'releases/1.0.0'
        manifest = stage.validate_archive(directory)
        source = directory / f"Mouthtype-{manifest['version']}-source.tar.gz"
        self.assertEqual(source.name, manifest['sourceArchive'])
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), manifest['sourceSHA256'])
        self.assertEqual((directory / f'{source.name}.sha256').read_text(),
                         f"{manifest['sourceSHA256']}  {source.name}\n")

    def test_package_manifest_gains_source_fields_and_passes_publish_checks(self):
        restore.restore(self.releases, self.public, self.download)
        self.check()
        restore.restore(self.releases, self.public, self.download)
        self.check()

    def test_staged_public_manifest_is_kept_as_is(self):
        manifest = json.loads(self.files['release-manifest.json'])
        manifest.update(sourceArchive='Mouthtype-1.0.0-source.tar.gz',
                        sourceSHA256=hashlib.sha256(b'src').hexdigest())
        self.files['release-manifest.json'] = json.dumps(manifest).encode()
        self.releases[0]['assets'] = [asset(n, d) for n, d in self.files.items()]
        restore.restore(self.releases, self.public, self.download)
        self.assertEqual((self.public / 'releases/1.0.0/release-manifest.json').read_bytes(),
                         self.files['release-manifest.json'])
        self.check()


if __name__ == '__main__':
    unittest.main()
