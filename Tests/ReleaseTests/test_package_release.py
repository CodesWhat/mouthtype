import importlib.util
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import zipfile

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/package-release.py'
spec = importlib.util.spec_from_file_location('package_release', SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseGuardsTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin", "Archive integration requires macOS ditto")
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

    def test_stable_version_without_prerelease_suffix_is_accepted(self):
        (self.root / 'packaging').mkdir()
        metadata = {'MouthtypeDisplayVersion': '0.1.0', 'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '15'}
        with (self.root / 'packaging/Version.plist').open('wb') as file:
            plistlib.dump(metadata, file)
        self.assertEqual(release.release_metadata(self.root)['MouthtypeDisplayVersion'], '0.1.0')

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


class NotaryAuthTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.directory = pathlib.Path(self._temp.name)

    def store(self, config, key_id=None):
        (self.directory / 'config.env').write_text(config)
        if key_id:
            (self.directory / 'private_keys').mkdir(exist_ok=True)
            (self.directory / 'private_keys' / f'AuthKey_{key_id}.p8').write_text('fake key')

    def test_release_build_env_is_repeatable_mode_at_the_fixed_scratch_path(self):
        env = release.release_build_env(pathlib.Path('/out/0.1.0'), {'MOUTHTYPE_UNSIGNED': '1', 'PATH': '/usr/bin'})
        self.assertEqual(env['MOUTHTYPE_SCRATCH_PATH'], release.RELEASE_SCRATCH_PATH)
        self.assertEqual(env['MOUTHTYPE_BUILD_DIR'], '/out/0.1.0')
        self.assertNotIn('MOUTHTYPE_UNSIGNED', env)
        self.assertEqual(env['PATH'], '/usr/bin')

    def test_api_key_is_the_default_when_the_key_file_exists(self):
        self.store('# comment\nexport ASC_KEY_ID=FAKEKEY123\nexport ASC_ISSUER_ID="fake-issuer-id"\n', 'FAKEKEY123')
        self.assertEqual(release.notary_auth(None, self.directory), [
            '--key', str(self.directory / 'private_keys/AuthKey_FAKEKEY123.p8'),
            '--key-id', 'FAKEKEY123', '--issuer', 'fake-issuer-id'])

    def test_keychain_profile_overrides_the_api_key(self):
        self.store('ASC_KEY_ID=FAKEKEY123\nASC_ISSUER_ID=fake-issuer-id\n', 'FAKEKEY123')
        self.assertEqual(release.notary_auth('some-profile', self.directory), ['--keychain-profile', 'some-profile'])

    def test_missing_key_file_or_config_is_rejected_without_a_profile(self):
        self.store('ASC_KEY_ID=FAKEKEY123\nASC_ISSUER_ID=fake-issuer-id\n')
        with self.assertRaises(RuntimeError):
            release.notary_auth(None, self.directory)
        with self.assertRaises(RuntimeError):
            release.notary_auth(None, self.directory / 'absent')

    def test_incomplete_config_is_rejected(self):
        self.store('ASC_KEY_ID=FAKEKEY123\n', 'FAKEKEY123')
        with self.assertRaises(RuntimeError):
            release.notary_auth(None, self.directory)


class DmgIdentityTests(unittest.TestCase):
    def test_returns_the_developer_id_authority(self):
        output = ('Executable=/x\nAuthority=Developer ID Application: CodesWhat (TEAM)\n'
                  'Authority=Developer ID Certification Authority\nAuthority=Apple Root CA\n')
        self.assertEqual(release.dmg_identity(output), 'Developer ID Application: CodesWhat (TEAM)')

    def test_missing_developer_id_is_rejected(self):
        for output in ['', 'Authority=Apple Root CA\n']:
            with self.subTest(output=output):
                with self.assertRaises(RuntimeError):
                    release.dmg_identity(output)


class NotarizeTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.output = pathlib.Path(self._temp.name)
        self.calls = []
        self.logs = []

    def fake_run(self, wait):
        def run(args, *, cwd=None, timeout=60, log=None):
            self.calls.append(list(args))
            verb = args[2]
            if log:
                self.logs.append((verb, pathlib.Path(log).name))
            if verb == 'submit':
                return '{"id":"abc"}'
            if verb == 'wait':
                if isinstance(wait, Exception):
                    raise wait
                return wait
            return ''
        return run

    def verbs(self):
        return [call[2] for call in self.calls]

    def test_accepted_submission_returns_the_id_and_writes_the_result(self):
        with unittest.mock.patch.object(release, 'run', self.fake_run('{"status":"Accepted"}')):
            submission_id, status = release.notarize(pathlib.Path('/x.zip'), ['--key', 'k'], self.output)
        self.assertEqual(submission_id, 'abc')
        self.assertEqual(status, {'status': 'Accepted'})
        result = json.loads((self.output / 'notarization-result.json').read_text())
        self.assertEqual(result, {'status': 'Accepted'})
        self.assertEqual(self.verbs(), ['submit', 'wait'])

    def test_rejected_submission_fetches_the_log_and_raises(self):
        with unittest.mock.patch.object(release, 'run', self.fake_run('{"status":"Invalid"}')):
            with self.assertRaisesRegex(RuntimeError, 'Invalid'):
                release.notarize(pathlib.Path('/x.zip'), ['--key', 'k'], self.output, 'dmg-')
        self.assertEqual(self.verbs(), ['submit', 'wait', 'log'])
        self.assertEqual(self.calls[-1][3], 'abc')
        self.assertEqual(self.logs, [('log', 'dmg-notarization-rejection.json')])

    def test_a_failed_wait_records_the_status_and_propagates(self):
        with unittest.mock.patch.object(release, 'run', self.fake_run(RuntimeError('wait timed out'))):
            with self.assertRaisesRegex(RuntimeError, 'wait timed out'):
                release.notarize(pathlib.Path('/x.zip'), [], self.output)
        self.assertEqual(self.verbs(), ['submit', 'wait', 'info'])
        self.assertEqual(self.logs, [('info', 'notarization-last-status.json')])
        self.assertFalse((self.output / 'notarization-result.json').exists())


class VerifyDiskImageTests(unittest.TestCase):
    def setUp(self):
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.output = pathlib.Path(self._temp.name)
        self.calls = []
        self.mount = None

    def fake_run(self, link):
        def run(args, *, cwd=None, timeout=60, log=None):
            self.calls.append(list(args))
            if args[0] == 'hdiutil' and args[1] == 'attach':
                self.mount = args[args.index('-mountpoint') + 1]
                if link is not None:
                    os.symlink(link, pathlib.Path(self.mount) / 'Applications')
            return ''
        return run

    def assessed_apps(self):
        return [c[-1] for c in self.calls if c[:2] == ['spctl', '--assess'] and c[-1].endswith('Mouthtype.app')]

    def test_good_image_verifies_the_app_inside(self):
        with unittest.mock.patch.object(release, 'run', self.fake_run('/Applications')):
            release.verify_disk_image(pathlib.Path('/m.dmg'), self.output, 'dmg')
        app = f'{self.mount}/Mouthtype.app'
        self.assertIn(['codesign', '--verify', '--deep', '--strict', app], self.calls)
        self.assertIn(['xcrun', 'stapler', 'validate', app], self.calls)
        self.assertEqual(self.assessed_apps(), [app])
        self.assertEqual(self.calls[-1], ['hdiutil', 'detach', self.mount])

    def test_missing_or_wrong_applications_link_raises_and_still_detaches(self):
        for link in [None, '/elsewhere']:
            with self.subTest(link=link):
                self.calls.clear()
                with unittest.mock.patch.object(release, 'run', self.fake_run(link)):
                    with self.assertRaisesRegex(RuntimeError, 'Applications'):
                        release.verify_disk_image(pathlib.Path('/m.dmg'), self.output, 'dmg')
                self.assertEqual(self.calls[-1], ['hdiutil', 'detach', self.mount])
                self.assertEqual(self.assessed_apps(), [])


if __name__ == '__main__':
    unittest.main()
