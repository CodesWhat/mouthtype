import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/publish-website.py'
spec = importlib.util.spec_from_file_location('website_publish_gates', SCRIPT)
website_publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(website_publish)

SPARKLE = 'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'


class PublishWebsiteGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mouthtype-publish-gates-')
        self.addCleanup(temporary.cleanup)
        self.assets = Path(temporary.name) / 'assets'
        self.release = self.assets / 'releases/0.9.1'
        self.release.mkdir(parents=True)
        self.archive = self.release / 'Mouthtype-0.9.1-macos-arm64.zip'
        self.archive.write_bytes(b'archive')
        self.source = self.release / 'Mouthtype-0.9.1-source.tar.gz'
        self.source.write_bytes(b'source')
        (self.release / 'release-manifest.json').write_text('{}')
        (self.assets / 'updates').mkdir()
        self.feed_build = '24'
        self.write_feed()
        self.manifest = {
            'version': '0.9.1', 'build': '24', 'archive': self.archive.name,
            'sourceArchive': self.source.name, 'sourceSHA256': hashlib.sha256(b'source').hexdigest(),
        }
        self.dirty = ''
        self.config = self.routes(self.archive.name, self.source.name)
        self.commands = []

    def write_feed(self):
        (self.assets / 'updates/appcast.xml').write_text(
            f'<rss {SPARKLE}><channel><item><sparkle:version>{self.feed_build}</sparkle:version></item></channel></rss>')

    @staticmethod
    def routes(download, source):
        return {'routes': [{'src': endpoint, 'status': 302, 'headers': {'Location': destination}}
                           for endpoint, destination in [('/download/file', '/releases/0.9.1/' + download),
                                                         ('/source', '/releases/0.9.1/' + source)]]}

    def releases(self):
        base = 'https://github.com/CodesWhat/mouthtype/releases/download/v0.9.1/'
        assets = [{'name': path.name, 'state': 'uploaded', 'size': path.stat().st_size,
                   'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(),
                   'browser_download_url': base + path.name} for path in (self.archive, self.source)]
        return [{'tag_name': 'v0.9.1', 'draft': False, 'assets': assets}]

    def run_main(self, *extra):
        def run(command, **kwargs):
            self.commands.append(command)
            if command[:3] == ['git', 'status', '--porcelain']:
                return self.dirty
            if command == ['git', 'rev-parse', 'HEAD']:
                return 'publisher-revision'
            if command[:3] == ['git', 'rev-parse', '--verify']:
                return 'website-revision'
            if command[:2] == ['git', 'show']:
                return json.dumps(self.config)
            if command[:2] == ['git', 'archive']:
                output = next(part for part in command if part.startswith('--output='))
                tar_path = Path(output.split('=', 1)[1])
                tar_path.write_bytes(b'')
                return ''
            if command[0] == 'tar':
                staging = Path(command[command.index('-C') + 1])
                (staging / 'website').mkdir()
                (staging / 'website/vercel.json').write_text(json.dumps({'routes': []}))
                return ''
            if command[0].endswith('/sign_update'):
                return ''
            if command[:2] == ['gh', 'api']:
                return json.dumps([self.releases()])
            if command[0] == 'vercel':
                return 'https://deployment.example'
            self.fail(f'Unexpected command: {command}')

        output = io.StringIO()
        argv = ['publish-website', '--public-dir', str(self.assets), *extra]
        with patch.object(website_publish, 'run', side_effect=run), \
                patch.object(website_publish.public, 'validate_archive', return_value=self.manifest), \
                patch('sys.argv', argv), patch('sys.stdout', output):
            website_publish.main()
        return output.getvalue()

    def deploys(self):
        return [command for command in self.commands if command[0] == 'vercel']

    def test_dirty_checkout_is_refused_before_anything_else(self):
        self.dirty = ' M website/index.html\n'
        with self.assertRaisesRegex(RuntimeError, 'clean reviewed checkout'):
            self.run_main('--production')
        self.assertEqual(self.commands, [['git', 'status', '--porcelain']])

    def test_missing_retained_artifacts_are_refused(self):
        (self.release / 'release-manifest.json').unlink()
        with self.assertRaisesRegex(RuntimeError, 'Retained public release artifacts'):
            self.run_main()

    def test_source_archive_checksum_must_match_the_manifest(self):
        self.source.write_bytes(b'tampered source')
        with self.assertRaisesRegex(RuntimeError, 'source archive checksum'):
            self.run_main()

    def test_advertised_download_must_be_a_checked_artifact(self):
        self.config = self.routes('Mouthtype-0.9.1-other.zip', self.source.name)
        with self.assertRaisesRegex(RuntimeError, 'not among the checked artifacts'):
            self.run_main('--production')
        self.assertEqual(self.deploys(), [])

    def test_a_release_with_a_dmg_must_advertise_the_dmg(self):
        self.manifest['dmg'] = 'Mouthtype-0.9.1-macos-arm64.dmg'
        with self.assertRaisesRegex(RuntimeError, 'must advertise the DMG'):
            self.run_main()

    def test_download_and_source_routes_must_describe_the_same_release(self):
        self.config = self.routes(self.archive.name, 'Mouthtype-0.8.0-source.tar.gz')
        with self.assertRaisesRegex(RuntimeError, 'same release'):
            self.run_main()

    def test_feed_must_not_lag_the_advertised_build(self):
        self.feed_build = '23'
        self.write_feed()
        with self.assertRaisesRegex(RuntimeError, 'newest build'):
            self.run_main()

    def test_check_mode_never_deploys(self):
        output = self.run_main()
        self.assertIn('nothing published', output)
        self.assertEqual(self.deploys(), [])

    def test_production_deploys_the_reviewed_revisions_with_provenance(self):
        output = self.run_main('--production')
        (command,) = self.deploys()
        self.assertEqual(command[:2], ['vercel', 'deploy'])
        for flag in ('--prod', '--yes'):
            self.assertIn(flag, command)
        self.assertEqual(command[command.index('--scope') + 1], 'codeswhat')
        meta = [command[i + 1] for i, part in enumerate(command) if part == '--meta']
        self.assertEqual(sorted(meta), ['sourceCommit=publisher-revision',
                                        'sourceRepository=CodesWhat/mouthtype',
                                        'websiteCommit=website-revision'])
        self.assertIn('Published release 0.9.1', output)
        self.assertNotIn('nothing published', output)


if __name__ == '__main__':
    unittest.main()
