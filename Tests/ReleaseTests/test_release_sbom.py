import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/generate-release-sbom.py'
spec = importlib.util.spec_from_file_location('release_sbom', SCRIPT)
sbom = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sbom)


class ReleaseSBOMTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.revision = 'a' * 40
        self.manifest = {'version': '1.2.3', 'tag': 'v1.2.3', 'sourceRevision': self.revision}
        for key, suffix in [('archive', 'zip'), ('dmg', 'dmg')]:
            name = f'Mouthtype-1.2.3-macos-arm64.{suffix}'
            data = f'synthetic {suffix}'.encode()
            (self.directory / name).write_bytes(data)
            self.manifest[key] = name
            self.manifest[f'{key}SHA256'] = hashlib.sha256(data).hexdigest()
        self.pins = {'pins': [{'identity': 'example', 'kind': 'remoteSourceControl',
                              'location': 'https://github.com/example/library.git',
                              'state': {'version': '2.0.0', 'revision': 'b' * 40}}]}

    def generate(self):
        return sbom.generate(self.manifest, self.pins, self.revision, self.directory)

    def test_inventory_binds_source_and_verified_artifacts_without_local_paths(self):
        result = self.generate()
        self.assertEqual(result['bomFormat'], 'CycloneDX')
        self.assertEqual(result['specVersion'], '1.6')
        root = result['metadata']['component']
        self.assertEqual(root['version'], '1.2.3')
        self.assertIn(self.revision, json.dumps(root))
        package = next(c for c in result['components'] if c['type'] == 'library')
        self.assertEqual(package['version'], '2.0.0')
        self.assertIn('#' + 'b' * 40, json.dumps(package))
        for key in ['archive', 'dmg']:
            artifact = next(c for c in result['components'] if c['name'] == self.manifest[key])
            self.assertEqual(artifact['hashes'], [{'alg': 'SHA-256', 'content': self.manifest[key + 'SHA256']}])
        self.assertEqual(result['compositions'][0]['aggregate'], 'incomplete')
        self.assertNotIn(str(self.directory), json.dumps(result))
        self.assertNotIn('dependencies', result)
        self.assertEqual(result, self.generate())

    def test_changed_artifact_is_rejected(self):
        (self.directory / self.manifest['archive']).write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            self.generate()

    def test_missing_artifact_is_rejected(self):
        (self.directory / self.manifest['dmg']).unlink()
        with self.assertRaises(FileNotFoundError):
            self.generate()

    def test_revision_and_tag_must_match(self):
        self.manifest['sourceRevision'] = 'c' * 40
        with self.assertRaisesRegex(ValueError, 'revision'):
            self.generate()
        self.manifest['sourceRevision'] = self.revision
        self.manifest['tag'] = 'v0.0.0'
        with self.assertRaisesRegex(ValueError, 'tag'):
            self.generate()

    def test_unpinned_or_duplicate_sources_are_rejected(self):
        self.pins['pins'][0]['state']['revision'] = 'main'
        with self.assertRaisesRegex(ValueError, 'revision'):
            self.generate()
        self.pins['pins'][0]['state']['revision'] = 'b' * 40
        self.pins['pins'].append(self.pins['pins'][0])
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            self.generate()

    def test_artifact_name_must_match_version(self):
        self.manifest['archive'] = '../outside.zip'
        with self.assertRaisesRegex(ValueError, 'filename'):
            self.generate()


if __name__ == '__main__':
    unittest.main()
