import importlib.util
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('linux_install', Path(__file__).with_name('install.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
ROOT = Path(__file__).resolve().parents[2]


class InstallTests(unittest.TestCase):
    def test_staging_uses_final_prefix_in_launcher_without_writing_there(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = (Path(temp) / 'final').resolve()
            staging = (Path(temp) / 'package').resolve()
            launcher = installer.install(ROOT, runtime, destdir=staging)
            staged_prefix = staging / runtime.relative_to('/')
            self.assertEqual(launcher, staged_prefix / 'bin/mouthtype-linux')
            self.assertFalse(runtime.exists(), 'Packaging must not write into the final prefix')
            self.assertTrue((staged_prefix / 'lib/mouthtype-linux/tools/linux-desktop/desktop.py').is_file())
            self.assertEqual((staged_prefix / 'lib/mouthtype-linux').stat().st_mode & 0o777, 0o755)
            text = launcher.read_text()
            self.assertIn(str(runtime / 'lib/mouthtype-linux/tools/linux-desktop/desktop.py'), text)
            self.assertNotIn(str(staging), text)

    def test_staging_cli_preserves_existing_final_install_and_requires_absolute_prefix(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = (Path(temp) / 'final').resolve()
            runtime.mkdir()
            (runtime / 'mine').write_text('keep')
            staging = Path(temp) / 'staging'
            result = subprocess.run(['python3', str(Path(installer.__file__)), '--prefix', str(runtime),
                                     '--destdir', str(staging)], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((runtime / 'mine').read_text(), 'keep')
            with self.assertRaises(ValueError):
                installer.install(ROOT, 'relative', destdir=Path(temp) / 'other')
            self.assertFalse((Path(temp) / 'other').exists())

    def test_install_is_runnable_and_preserves_existing_config(self):
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp) / 'local'
            config = prefix / 'config.json'
            prefix.mkdir()
            config.write_text('user content')
            installer.install(ROOT, prefix)
            launcher = prefix / 'bin/mouthtype-linux'
            self.assertTrue(launcher.is_file())
            self.assertEqual((prefix / 'lib/mouthtype-linux').stat().st_mode & 0o777, 0o700)
            result = subprocess.run([str(launcher), '--help'], capture_output=True, text=True,
                                    check=True, timeout=5)
            self.assertIn('toggle', result.stdout)
            self.assertIn('transcribe', result.stdout)
            checks = subprocess.run([str(launcher), 'recover', '--help'], capture_output=True,
                                    text=True, check=True, timeout=5)
            self.assertIn('--raw', checks.stdout)
            payload = prefix / 'lib/mouthtype-linux/tools/linux-desktop'
            checks = subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', str(payload),
                                     '-p', 'test_spellings.py'], cwd=temp, capture_output=True,
                                    text=True, timeout=5)
            self.assertEqual(checks.returncode, 0, checks.stderr)
            self.assertEqual(config.read_text(), 'user content')
            with self.assertRaises(FileExistsError):
                installer.install(ROOT, prefix)
    def test_existing_launcher_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp)
            (prefix / 'bin').mkdir()
            launcher = prefix / 'bin/mouthtype-linux'
            launcher.write_text('previous')
            with self.assertRaises(FileExistsError):
                installer.install(ROOT, prefix)
            self.assertEqual(launcher.read_text(), 'previous')
    def test_package_has_runtime_license_and_no_private_or_model_files(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'linux.tar.gz'
            installer.package(ROOT, output)
            self.assertTrue(output.is_file())
            with tarfile.open(output) as archive:
                names = archive.getnames()
                self.assertIn('mouthtype-linux/LICENSE', names)
                self.assertIn('mouthtype-linux/tools/linux-desktop/desktop.py', names)
                self.assertIn('mouthtype-linux/tools/linux-engine-proof/worker.py', names)
                self.assertIn('mouthtype-linux/tools/linux-desktop/vendor/grapheme/data/grapheme_break_property.json', names)
                self.assertIn('mouthtype-linux/tools/linux-desktop/vendor/grapheme/LICENSE', names)
                self.assertIn('mouthtype-linux/tools/linux-desktop/vendor/grapheme/UNICODE-LICENSE', names)
                self.assertIn('mouthtype-linux/tools/linux-desktop/spelling-unicode.json', names)
                self.assertFalse(any('.planning' in name or '.onnx' in name or '.gguf' in name for name in names))
            with self.assertRaises(FileExistsError):
                installer.package(ROOT, output)

if __name__ == '__main__':
    unittest.main()
