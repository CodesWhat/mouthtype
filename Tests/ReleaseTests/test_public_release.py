import hashlib
import importlib.util
import json
import pathlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'scripts/stage-public-release.py'
spec = importlib.util.spec_from_file_location('public_release', SCRIPT)
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)


class PublicReleaseTests(unittest.TestCase):
    def test_download_must_select_the_newest_feed_build_not_an_older_item(self):
        path = self.directory / 'appcast.xml'
        path.write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>4</sparkle:version></item><item><sparkle:version>5</sparkle:version></item></channel></rss>')
        with self.assertRaisesRegex(RuntimeError, 'newest'):
            public.validate_feed_build(path, '4')
        public.validate_feed_build(path, '5')

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='mouthtype-public-release-')
        self.addCleanup(self.temporary.cleanup)
        self.directory = pathlib.Path(self.temporary.name)
        self.archive = self.directory / 'Mouthtype-0.1.0-alpha.4-macos-arm64.zip'
        self.archive.write_bytes(b'verified release archive')
        self.manifest = {
            'version': '0.1.0-alpha.4', 'build': '4',
            'archive': self.archive.name,
            'archiveSHA256': hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            'archiveBytes': self.archive.stat().st_size,
            'notarizationStatus': 'Accepted', 'signatureVerified': True,
            'stapleVerified': True, 'extractedGatekeeperAccepted': True,
        }

    def validate(self):
        (self.directory / 'release-manifest.json').write_text(json.dumps(self.manifest))
        return public.validate_archive(self.directory)

    def test_accepts_the_exact_checked_archive(self):
        self.assertEqual(self.validate(), self.manifest)

    def test_rejects_changed_archive_even_if_its_length_is_unchanged(self):
        self.archive.write_bytes(b'verified release archivE')
        with self.assertRaisesRegex(RuntimeError, 'checksum'):
            self.validate()

    def test_rejects_missing_distribution_checks(self):
        for field in ('signatureVerified', 'stapleVerified', 'extractedGatekeeperAccepted'):
            with self.subTest(field=field):
                self.manifest[field] = False
                with self.assertRaisesRegex(RuntimeError, 'distribution checks'):
                    self.validate()
                self.manifest[field] = True

    def test_rejected_notarization_cannot_be_published(self):
        self.manifest['notarizationStatus'] = 'Invalid'
        with self.assertRaisesRegex(RuntimeError, 'notarization'):
            self.validate()

    def test_release_label_and_filename_must_agree(self):
        self.manifest['version'] = '0.1.0-alpha.5'
        with self.assertRaisesRegex(RuntimeError, 'filename'):
            self.validate()

    def test_retaining_a_new_release_keeps_older_downloads_and_replaces_only_the_feed(self):
        staged = self.directory / 'staged'
        retained = self.directory / 'retained'
        for folder in (staged / 'releases/new', staged / 'updates', retained / 'releases/old', retained / 'updates'):
            folder.mkdir(parents=True)
        (staged / 'releases/new/app.zip').write_bytes(b'new release')
        (staged / 'updates/appcast.xml').write_bytes(b'new signed feed')
        (retained / 'releases/old/app.zip').write_bytes(b'old release')
        (retained / 'updates/appcast.xml').write_bytes(b'old signed feed')
        public.retain_public_assets(staged, retained)
        self.assertEqual((retained / 'releases/old/app.zip').read_bytes(), b'old release')
        self.assertEqual((retained / 'releases/new/app.zip').read_bytes(), b'new release')
        self.assertEqual((retained / 'updates/appcast.xml').read_bytes(), b'new signed feed')

    def test_immutable_download_cannot_be_replaced_and_feed_stays_unchanged_on_failure(self):
        staged = self.directory / 'staged'
        retained = self.directory / 'retained'
        for folder in (staged / 'releases/same', staged / 'updates', retained / 'releases/same', retained / 'updates'):
            folder.mkdir(parents=True)
        (staged / 'releases/same/app.zip').write_bytes(b'changed bytes')
        (staged / 'updates/appcast.xml').write_bytes(b'new feed')
        (retained / 'releases/same/app.zip').write_bytes(b'published bytes')
        (retained / 'updates/appcast.xml').write_bytes(b'published feed')
        with self.assertRaisesRegex(RuntimeError, 'immutable'):
            public.retain_public_assets(staged, retained)
        self.assertEqual((retained / 'releases/same/app.zip').read_bytes(), b'published bytes')
        self.assertEqual((retained / 'updates/appcast.xml').read_bytes(), b'published feed')
