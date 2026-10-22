import ast
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
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

    def test_staging_permissions_ignore_restrictive_child_umask_without_changing_manual_install(self):
        with tempfile.TemporaryDirectory() as temp:
            staging = Path(temp) / 'package'
            manual = Path(temp) / 'manual'
            child = ('import os, runpy, sys; os.umask(0o077); '
                     'sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")')
            for arguments in (['--prefix', '/usr', '--destdir', str(staging)],
                              ['--prefix', str(manual)]):
                result = subprocess.run([sys.executable, '-c', child, str(Path(installer.__file__)),
                                         *arguments], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
            for path in (staging / 'usr', *(staging / 'usr').rglob('*')):
                expected = 0o755 if path.is_dir() or path.name == 'mouthtype-linux' else 0o644
                self.assertEqual(path.stat().st_mode & 0o777, expected, str(path))
            payload = manual / 'lib/mouthtype-linux'
            self.assertEqual(payload.stat().st_mode & 0o777, 0o700)
            self.assertEqual((payload / 'tools').stat().st_mode & 0o777, 0o700)
            self.assertEqual((payload / 'LICENSE').stat().st_mode & 0o777, 0o600)

    def test_staging_preserves_existing_ancestor_permissions(self):
        with tempfile.TemporaryDirectory() as temp:
            staging = Path(temp) / 'package'
            staging.mkdir(mode=0o700)
            ancestor = staging / 'usr'
            ancestor.mkdir(mode=0o750)
            child = ('import os, runpy, sys; os.umask(0o077); '
                     'sys.argv = sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")')
            result = subprocess.run([sys.executable, '-c', child, str(Path(installer.__file__)),
                                     '--prefix', '/usr/local', '--destdir', str(staging)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(staging.stat().st_mode & 0o777, 0o700)
            self.assertEqual(ancestor.stat().st_mode & 0o777, 0o750)
            self.assertEqual((ancestor / 'local').stat().st_mode & 0o777, 0o755)
            self.assertEqual((ancestor / 'local/lib').stat().st_mode & 0o777, 0o755)
            self.assertEqual((ancestor / 'local/bin').stat().st_mode & 0o777, 0o755)

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
            phrases = subprocess.run(['python3', '-W', 'error::ResourceWarning', '-m', 'unittest',
                                      'discover', '-s', str(payload), '-p', 'test_phrase*.py'],
                                     cwd=temp, capture_output=True, text=True, timeout=5)
            self.assertEqual(phrases.returncode, 0, phrases.stderr)
            cleanup = subprocess.run(['python3', '-W', 'error::ResourceWarning', '-m', 'unittest',
                                      'discover', '-s', str(payload), '-p', 'test_cleanup*.py'],
                                     cwd=temp, capture_output=True, text=True, timeout=5)
            self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
            self.assertEqual(config.read_text(), 'user content')
            with self.assertRaises(FileExistsError):
                installer.install(ROOT, prefix)
    def test_update_replaces_and_uninstall_removes_only_what_was_installed(self):
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp)
            installer.install(ROOT, prefix)
            (prefix / 'lib/mouthtype-linux/stale.txt').write_text('old')
            (prefix / 'bin/other').write_text('keep')
            installer.install(ROOT, prefix, update=True)
            self.assertFalse((prefix / 'lib/mouthtype-linux/stale.txt').exists())
            self.assertEqual(len(installer.uninstall(prefix)), 2 + len(installer.SHARE))
            self.assertFalse((prefix / 'lib/mouthtype-linux').exists())
            self.assertEqual((prefix / 'bin/other').read_text(), 'keep')
            self.assertEqual(installer.uninstall(prefix), [])

    def test_app_identity_files_install_under_the_prefix_and_uninstall_cleanly(self):
        app_id = installer.APP_ID
        self.assertEqual(app_id, 'app.mouthtype.Mouthtype')
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp) / 'prefix'
            installer.install(ROOT, prefix)
            desktop = prefix / 'share/applications' / (app_id + '.desktop')
            icon = prefix / 'share/icons/hicolor/128x128/apps' / (app_id + '.png')
            self.assertTrue(desktop.is_file())
            self.assertEqual(icon.read_bytes()[:8], b'\x89PNG\r\n\x1a\n')
            entry = dict(line.split('=', 1) for line in desktop.read_text().splitlines()
                         if '=' in line and not line.startswith('#'))
            self.assertEqual(entry['Icon'], app_id)
            self.assertEqual(entry['Type'], 'Application')
            self.assertTrue(entry['Name'] and entry['Exec'])
            installer.uninstall(prefix)
            self.assertFalse(desktop.exists())
            self.assertFalse(icon.exists())

    def test_app_identity_files_are_staged_with_package_permissions(self):
        with tempfile.TemporaryDirectory() as temp:
            staging = Path(temp) / 'package'
            installer.install(ROOT, '/usr', destdir=staging)
            for relative in ('usr/share/applications/app.mouthtype.Mouthtype.desktop',
                             'usr/share/icons/hicolor/128x128/apps/app.mouthtype.Mouthtype.png'):
                path = staging / relative
                self.assertEqual(path.stat().st_mode & 0o777, 0o644, relative)
                for parent in path.parents:
                    if parent == staging:
                        break
                    self.assertEqual(parent.stat().st_mode & 0o777, 0o755, str(parent))

    def test_desktop_file_validates_when_the_validator_is_present(self):
        validator = shutil.which('desktop-file-validate')
        if validator is None:
            self.skipTest('desktop-file-validate is not installed')
        result = subprocess.run([validator, str(ROOT / 'tools/linux-desktop/share/app.mouthtype.Mouthtype.desktop')],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_uninstall_refuses_a_foreign_launcher(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / 'bin').mkdir()
            (Path(temp) / 'bin/mouthtype-linux').write_text('#!/bin/sh\necho mine\n')
            with self.assertRaises(FileExistsError):
                installer.uninstall(temp)
            self.assertTrue((Path(temp) / 'bin/mouthtype-linux').exists())

    def test_existing_install_error_names_the_fix(self):
        with tempfile.TemporaryDirectory() as temp:
            installer.install(ROOT, temp)
            result = subprocess.run(['python3', str(Path(installer.__file__)), '--prefix', temp],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertIn('--update', result.stderr)
            self.assertIn('--uninstall', result.stderr)

    def test_existing_launcher_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp)
            (prefix / 'bin').mkdir()
            launcher = prefix / 'bin/mouthtype-linux'
            launcher.write_text('previous')
            with self.assertRaises(FileExistsError):
                installer.install(ROOT, prefix)
            self.assertEqual(launcher.read_text(), 'previous')
    def fake_source(self, root):
        for name in installer.FILES:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('x')
        for name, _ in installer.SHARE:
            path = root / 'tools/linux-desktop/share' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('x')
        desktop = root / 'tools/linux-desktop'
        for name in ('library.py', 'stats.py', 'tone.py', 'profanity.py', 'cli_library.py', 'cli_style.py',
                     'cli_transform.py', 'transform_worker.py', 'test_transform.py', 'test_arch_bundle.py',
                     'check_tone.py', 'verify_tone.py', 'conftest.py', 'notes.txt'):
            (desktop / name).write_text('x')

    def test_install_ships_runtime_modules_and_their_tests_but_not_dev_scripts(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'src'
            self.fake_source(source)
            prefix = Path(temp) / 'local'
            installer.install(source, prefix)
            installed = prefix / 'lib/mouthtype-linux/tools/linux-desktop'
            for name in ('library.py', 'stats.py', 'tone.py', 'profanity.py', 'cli_library.py',
                         'cli_style.py', 'cli_transform.py', 'transform_worker.py', 'test_transform.py'):
                self.assertTrue((installed / name).is_file(), name)
                self.assertEqual((installed / name).stat().st_mode, (installed / 'desktop.py').stat().st_mode, name)
            for name in ('test_arch_bundle.py', 'check_tone.py', 'verify_tone.py', 'conftest.py', 'notes.txt'):
                self.assertFalse((installed / name).exists(), name)
            output = Path(temp) / 'linux.tar.gz'
            installer.package(source, output)
            with tarfile.open(output) as archive:
                names = archive.getnames()
            self.assertIn('mouthtype-linux/tools/linux-desktop/tone.py', names)
            self.assertIn('mouthtype-linux/tools/linux-desktop/cli_transform.py', names)
            self.assertNotIn('mouthtype-linux/tools/linux-desktop/check_tone.py', names)
            self.assertIn('mouthtype-linux/tools/linux-desktop/transform_worker.py', names)
            self.assertIn('mouthtype-linux/tools/linux-desktop/test_transform.py', names)
            self.assertNotIn('mouthtype-linux/tools/linux-desktop/test_arch_bundle.py', names)

    def test_every_module_the_payload_imports_is_shipped(self):
        """A runtime import of a file install.py doesn't ship fails only on an installed machine, so walk the imports."""
        desktop = ROOT / 'tools/linux-desktop'
        shipped = set(installer.payload_files(ROOT))
        for name in ('portal.py', 'delivery_portal.py', 'atspi_target.py', 'shortcuts_portal.py', 'concealed.py',
                     'backends/__init__.py', 'testing/__init__.py', 'testing/fake_portal.py'):
            self.assertIn('tools/linux-desktop/' + name, shipped, name)
        missing = set()
        for name in sorted(shipped):
            if not name.startswith('tools/linux-desktop/') or not name.endswith('.py'):
                continue
            tree = ast.parse((ROOT / name).read_text(), name)
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    modules = [alias.name for alias in node.names]
                elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
                    modules = [node.module] + [node.module + '.' + alias.name for alias in node.names]
                else:
                    continue
                for module in modules:
                    relative = module.replace('.', '/')
                    for candidate in (relative + '.py', relative + '/__init__.py'):
                        if (desktop / candidate).is_file() and not candidate.startswith('vendor/'):
                            if 'tools/linux-desktop/' + candidate not in shipped:
                                missing.add((name, candidate))
        self.assertEqual(sorted(missing), [])

    def test_packaging_installs_through_install_py(self):
        for script in ('packaging/debian/build-deb.sh', 'packaging/rpm/mouthtype-linux.spec.in',
                       'packaging/arch/aur/PKGBUILD', 'packaging/arch/PKGBUILD.in'):
            self.assertIn('tools/linux-desktop/install.py', (ROOT / script).read_text(), script)

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

    def test_launcher_imports_desktop_as_a_module_so_bytecode_is_cached(self):
        with tempfile.TemporaryDirectory() as temp:
            prefix = Path(temp) / 'local'
            launcher = installer.install(ROOT, prefix)
            text = launcher.read_text()
            self.assertIn('import desktop', text)
            self.assertNotIn('runpy', text)
            subprocess.run([str(launcher), 'capabilities'], capture_output=True, text=True, check=True, timeout=10)
            self.assertTrue(list((prefix / 'lib/mouthtype-linux/tools/linux-desktop/__pycache__').glob('desktop.*.pyc')))


if __name__ == '__main__':
    unittest.main()
