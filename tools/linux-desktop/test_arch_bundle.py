import hashlib
import importlib.util
import json
import plistlib
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('arch_bundle', ROOT / 'scripts/prepare-linux-arch.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class ArchBundleTests(unittest.TestCase):
    def test_cli_selects_prerelease_version_before_matching_stable(self):
        base = plistlib.loads((ROOT / 'packaging/Version.plist').read_bytes())['CFBundleShortVersionString']
        def git(argv, **_):
            return '' if 'status' in argv else ('a' * 40 if 'rev-parse' in argv else '1700000000')
        with patch.object(bundle.sys, 'argv', ['prepare-linux-arch', '--destination', '/unused']), \
                patch.object(bundle.subprocess, 'check_output', side_effect=git), \
                patch.object(bundle, 'prepare', return_value=Path('/unused')) as prepare, patch('builtins.print'):
            self.assertEqual(bundle.main(), 0)
        self.assertEqual(prepare.call_args.kwargs['version'], base + 'test.r1700000000.' + 'a' * 12)

    def test_local_bundle_has_literal_source_integrity_and_private_source_exclusions(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'bundle'
            bundle.prepare(ROOT, output, version='0.1.0.test.r42.abcdef123456', revision='a' * 40)
            self.assertTrue((output / 'PKGBUILD').is_file())
            recipe = (output / 'PKGBUILD').read_text()
            source = output / 'mouthtype-linux-source.tar.gz'
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            self.assertIn("sha256sums=('" + digest + "')", recipe)
            self.assertIn('pkgver=0.1.0.test.r42.abcdef123456', recipe)
            self.assertNotIn('SKIP', recipe)
            self.assertNotIn('https://', recipe.split('source=(')[1].split(')')[0])
            self.assertNotIn('@VERSION@', recipe)
            subprocess.run(['bash', '-n', str(output / 'PKGBUILD')], check=True, timeout=5)
            with tarfile.open(source) as archive:
                self.assertTrue(all(m.isfile() for m in archive.getmembers()))
                self.assertFalse(any('.planning' in m.name or '.onnx' in m.name or '.gguf' in m.name for m in archive.getmembers()))
                raw = archive.extractfile('mouthtype-linux/tools/linux-desktop/install.py').read()
                self.assertEqual(raw, (ROOT / 'tools/linux-desktop/install.py').read_bytes())
            receipt = json.loads((output / 'BUILD-SOURCE.json').read_text())
            self.assertEqual(receipt['revision'], 'a' * 40)
            self.assertEqual(receipt['source_sha256'], digest)
            self.assertFalse(receipt['physical_desktop_tested'])
            self.assertEqual(len(receipt['payload_sha256']), len(bundle.installer.payload_files(ROOT)))

    def test_existing_output_and_invalid_metadata_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'bundle'
            output.mkdir()
            (output / 'mine').write_text('keep')
            with self.assertRaises(FileExistsError):
                bundle.prepare(ROOT, output, version='0.1.0.test.r1.abc', revision='a' * 40)
            self.assertEqual((output / 'mine').read_text(), 'keep')
            for version in ('../bad', 'bad; echo x', '1:2', '1-2', '1\n2'):
                fresh = Path(directory) / 'fresh'
                with self.subTest(version=version), self.assertRaises(ValueError):
                    bundle.prepare(ROOT, fresh, version=version, revision='a' * 40)
                self.assertFalse(fresh.exists())


if __name__ == '__main__':
    unittest.main()
