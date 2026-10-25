import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('xcrun'), 'requires the macOS coverage tools')
class SwiftCoverageTests(unittest.TestCase):
    def test_report_includes_every_test_binary(self):
        with tempfile.TemporaryDirectory(prefix='mouthtype-coverage-') as temporary:
            directory = pathlib.Path(temporary)
            products = directory / 'products'
            codecov = products / 'codecov'
            codecov.mkdir(parents=True)
            profiles = []
            for name in ('First', 'Second'):
                source = directory / f'{name}.c'
                source.write_text('int main(void) { return 0; }\n')
                binary = products / f'{name}.xctest' / 'Contents/MacOS' / name
                binary.parent.mkdir(parents=True)
                subprocess.run([
                    'xcrun', 'clang', '-fprofile-instr-generate', '-fcoverage-mapping',
                    str(source), '-o', str(binary),
                ], check=True, capture_output=True)
                profile = directory / f'{name}.profraw'
                subprocess.run([str(binary)], env={**os.environ, 'LLVM_PROFILE_FILE': str(profile)}, check=True)
                profiles.append(str(profile))
            subprocess.run([
                'xcrun', 'llvm-profdata', 'merge', *profiles, '-o', str(codecov / 'default.profdata'),
            ], check=True, capture_output=True)
            commands = directory / 'bin'
            commands.mkdir()
            swift = commands / 'swift'
            swift.write_text(f'#!/bin/sh\necho "{codecov}/Mouthtype.json"\n')
            swift.chmod(0o755)
            result = subprocess.run(
                ['bash', str(ROOT / 'scripts/swift-coverage.sh')], cwd=directory,
                env={
                    **os.environ, 'PATH': f'{commands}:{os.environ["PATH"]}',
                    'GITHUB_STEP_SUMMARY': str(directory / 'summary.md'),
                },
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = (directory / 'coverage-report.txt').read_text()
            self.assertIn('First.c', report)
            self.assertIn('Second.c', report)
            self.assertIn('Total line coverage: 100.00%', (directory / 'summary.md').read_text())
            self.assertIn('Swift_line_coverage-100.00%25-blue', (directory / 'summary.md').read_text())


class CoverageFloorTests(unittest.TestCase):
    def test_floor_uses_exact_line_counts(self):
        for lines, missed, displayed, passes in (
            (100, 20, '80.00', True),
            (100, 19, '81.00', True),
            (10000, 2001, '79.99', False),
            (100000, 20001, '80.00', False),
            (0, 0, '100.00', False),
        ):
            with self.subTest(lines=lines, missed=missed, displayed=displayed):
                with tempfile.TemporaryDirectory(prefix='mouthtype-coverage-floor-') as temporary:
                    directory = pathlib.Path(temporary)
                    products = directory / 'products'
                    codecov = products / 'codecov'
                    codecov.mkdir(parents=True)
                    (codecov / 'default.profdata').touch()
                    binary = products / 'First.xctest/Contents/MacOS/First'
                    binary.parent.mkdir(parents=True)
                    binary.touch()
                    commands = directory / 'bin'
                    commands.mkdir()
                    swift = commands / 'swift'
                    swift.write_text(f'#!/bin/sh\necho "{codecov}/Mouthtype.json"\n')
                    swift.chmod(0o755)
                    xcrun = commands / 'xcrun'
                    xcrun.write_text(
                        '#!/bin/sh\n'
                        f'echo "TOTAL 1 0 100.00% 1 0 100.00% {lines} {missed} {displayed}% 0 0 -"\n'
                    )
                    xcrun.chmod(0o755)
                    result = subprocess.run(
                        ['bash', str(ROOT / 'scripts/swift-coverage.sh')], cwd=directory,
                        env={**os.environ, 'PATH': f'{commands}:{os.environ["PATH"]}',
                             'GITHUB_STEP_SUMMARY': str(directory / 'summary.md')},
                        text=True, capture_output=True,
                    )
                    self.assertEqual(result.returncode == 0, passes, result.stdout + result.stderr)
                    self.assertIn('Swift_line_coverage', (directory / 'summary.md').read_text())
