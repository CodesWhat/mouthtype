import importlib.util
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/package-release.py'
spec = importlib.util.spec_from_file_location('package_release', SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseGuardsTests(unittest.TestCase):
    def test_update_zip_places_only_the_app_at_the_archive_root(self):
        app = self.root / 'Mouthtype.app'
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(b'fixture app metadata')
        archive = self.root / 'update.zip'
        release.create_update_archive(app, archive)
        with zipfile.ZipFile(archive) as zipped:
            paths = [name for name in zipped.namelist() if not name.startswith('__MACOSX/')]
            self.assertTrue(paths)
            self.assertTrue(all(name.startswith('Mouthtype.app/') for name in paths), paths)
            self.assertEqual(zipped.read('Mouthtype.app/Contents/Info.plist'), b'fixture app metadata')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mouthtype-release-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        (self.root / 'source.txt').write_text('reviewed source\n')
        self.git('add', 'source.txt')
        self.git('commit', '-qm', 'initial fixture')
        self.git('tag', 'v0.1.0-alpha.1')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True).strip()

    def test_exact_clean_tag_is_accepted(self):
        self.assertEqual(release.verify_source(self.root, '0.1.0-alpha.1'), self.git('rev-parse', 'HEAD'))

    def test_dirty_tracked_or_untracked_source_cannot_ship(self):
        for name in ['source.txt', 'unreviewed.txt']:
            with self.subTest(name=name):
                path = self.root / name
                path.write_text('unreviewed change\n')
                with self.assertRaisesRegex(RuntimeError, 'clean'):
                    release.verify_source(self.root, '0.1.0-alpha.1')
                if name == 'source.txt':
                    self.git('restore', name)
                else:
                    path.unlink()

    def test_a_commit_after_the_tag_cannot_ship_under_that_version(self):
        (self.root / 'source.txt').write_text('later source\n')
        self.git('commit', '-qam', 'later fixture')
        with self.assertRaisesRegex(RuntimeError, 'tag'):
            release.verify_source(self.root, '0.1.0-alpha.1')

    def test_invalid_or_inconsistent_bundle_metadata_is_rejected(self):
        (self.root / 'packaging').mkdir()
        metadata = {'MouthtypeDisplayVersion': '0.1.0-alpha.1', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '1'}
        path = self.root / 'packaging/Version.plist'
        for key, value in [('CFBundleShortVersionString', '0.2.0'), ('CFBundleVersion', '0'), ('MouthtypeDisplayVersion', '0.1.0-alpha.0')]:
            with self.subTest(key=key):
                with path.open('wb') as file:
                    plistlib.dump({**metadata, key: value}, file)
                with self.assertRaises(RuntimeError):
                    release.release_metadata(self.root)

    def test_the_existing_release_directory_is_never_reused(self):
        output = self.root / 'output'
        existing = output / '0.1.0-alpha.1'
        existing.mkdir(parents=True)
        marker = existing / 'keep.txt'
        marker.write_text('preserve this artifact')
        with self.assertRaises(FileExistsError):
            release.create_output(output, '0.1.0-alpha.1')
        self.assertEqual(marker.read_text(), 'preserve this artifact')


if __name__ == '__main__':
    unittest.main()
