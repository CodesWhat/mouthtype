import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/publish-website.py'
spec = importlib.util.spec_from_file_location('website_publish', SCRIPT)
website_publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(website_publish)


class WebsiteDownloadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mouthtype-download-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.assets = self.root / 'assets'
        self.release = self.assets / 'releases/0.9.1'
        self.release.mkdir(parents=True)
        self.archive = self.release / 'Mouthtype-0.9.1-macos-arm64.zip'
        self.archive.write_bytes(b'signed release bytes')
        self.url = 'https://github.com/CodesWhat/mouthtype/releases/download/v0.9.1/' + self.archive.name
        self.releases = [{
            'tag_name': 'v0.9.1', 'draft': False, 'assets': [{
                'name': self.archive.name, 'state': 'uploaded',
                'size': self.archive.stat().st_size,
                'digest': 'sha256:' + hashlib.sha256(self.archive.read_bytes()).hexdigest(),
                'browser_download_url': self.url,
            }],
        }]

    def test_existing_versioned_url_redirects_to_exact_verified_release_asset(self):
        routes = website_publish.external_download_routes(self.assets, self.releases)
        self.assertEqual(len(routes), 1)
        self.assertEqual(routes[0]['headers']['Location'], self.url)
        self.assertEqual(routes[0]['status'], 302)
        import re
        self.assertIsNotNone(re.fullmatch(routes[0]['src'], '/releases/0.9.1/' + self.archive.name))
        self.assertIsNone(re.fullmatch(routes[0]['src'], '/releases/0x9x1/' + self.archive.name))

    def test_missing_draft_or_changed_remote_asset_blocks_publication(self):
        for field, value in [('digest', 'sha256:' + '0' * 64), ('size', 1),
                             ('browser_download_url', 'https://example.com/app.zip'), ('state', 'new')]:
            with self.subTest(field=field):
                releases = json.loads(json.dumps(self.releases))
                releases[0]['assets'][0][field] = value
                with self.assertRaises(RuntimeError):
                    website_publish.external_download_routes(self.assets, releases)
        for releases in [[], [{**self.releases[0], 'draft': True}],
                         [{**self.releases[0], 'assets': []}]]:
            with self.assertRaises(RuntimeError):
                website_publish.external_download_routes(self.assets, releases)

    def test_staging_keeps_signed_feed_and_metadata_without_large_downloads(self):
        image = self.release / 'Mouthtype-0.9.1-macos-arm64.dmg'
        image.write_bytes(b'image')
        source = self.release / 'Mouthtype-0.9.1-source.tar.gz'
        source.write_bytes(b'source')
        (self.release / 'release-manifest.json').write_bytes(b'manifest')
        (self.release / (self.archive.name + '.sha256')).write_bytes(b'checksum')
        (self.assets / 'updates').mkdir()
        (self.assets / 'updates/appcast.xml').write_bytes(b'unchanged signed feed')
        site = self.root / 'website'
        site.mkdir()
        (site / 'vercel.json').write_text(json.dumps({'routes': [{'src': '/source', 'status': 302}]}))
        routes = [{'src': '/download-test', 'headers': {'Location': self.url}, 'status': 302}]
        website_publish.stage_public_assets(self.assets, site, routes)
        self.assertEqual((site / 'public/updates/appcast.xml').read_bytes(), b'unchanged signed feed')
        self.assertEqual((site / 'public/releases/0.9.1/release-manifest.json').read_bytes(), b'manifest')
        self.assertEqual((site / 'public/releases/0.9.1' / (self.archive.name + '.sha256')).read_bytes(), b'checksum')
        self.assertFalse(any(p.suffix in {'.zip', '.dmg', '.gz'} for p in (site / 'public/releases').rglob('*')))
        self.assertEqual(json.loads((site / 'vercel.json').read_text())['routes'][-1], routes[0])

    def test_pinned_reviewed_website_selects_its_published_release_without_deploying(self):
        source = self.release / 'Mouthtype-0.9.1-source.tar.gz'
        source.write_bytes(b'committed source')
        self.releases[0]['assets'].append({
            'name': source.name, 'state': 'uploaded', 'size': source.stat().st_size,
            'digest': 'sha256:' + hashlib.sha256(source.read_bytes()).hexdigest(),
            'browser_download_url': self.url.rsplit('/', 1)[0] + '/' + source.name,
        })
        (self.release / 'release-manifest.json').write_text('{}')
        manifest = {'version': '0.9.1', 'build': '24', 'archive': self.archive.name,
                    'sourceArchive': source.name, 'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest()}
        (self.assets / 'updates').mkdir()
        (self.assets / 'updates/appcast.xml').write_text(
            '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
            '<item><sparkle:version>24</sparkle:version></item></channel></rss>')
        config = {'routes': [{'src': endpoint, 'status': 302, 'headers': {'Location': destination}}
                             for endpoint, destination in [('/download/file', '/releases/0.9.1/' + self.archive.name),
                                                           ('/source', '/releases/0.9.1/' + source.name)]]}

        def run(command, **kwargs):
            if command[:3] == ['git', 'status', '--porcelain']:
                return ''
            if command == ['git', 'rev-parse', 'HEAD']:
                return 'publisher-revision'
            if command[:3] == ['git', 'rev-parse', '--verify']:
                return 'reviewed-website-revision'
            if command == ['git', 'show', 'reviewed-website-revision:website/vercel.json']:
                return json.dumps(config)
            if command[0].endswith('/sign_update'):
                return ''
            if command[:2] == ['gh', 'api']:
                return json.dumps([self.releases])
            self.fail(f'Unexpected command or deployment: {command}')

        output = io.StringIO()
        with patch.object(website_publish, 'run', side_effect=run), \
                patch.object(website_publish.public, 'validate_archive', return_value=manifest), \
                patch('sys.argv', ['publish-website', '--public-dir', str(self.assets), '--website-ref', 'reviewed-live-site']), \
                patch('sys.stdout', output):
            website_publish.main()
        self.assertIn('reviewed-website-revision', output.getvalue())
        self.assertIn('release 0.9.1', output.getvalue())
        self.assertIn('nothing published', output.getvalue())
