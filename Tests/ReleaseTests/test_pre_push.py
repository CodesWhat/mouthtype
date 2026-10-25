import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class PrePushTests(unittest.TestCase):
    def test_mixed_changes_still_run_the_swift_checks(self):
        with tempfile.TemporaryDirectory(prefix='mouthtype-pre-push-') as temporary:
            directory = pathlib.Path(temporary)
            commands = directory / 'bin'
            commands.mkdir()
            for name in ('swift', 'xcrun'):
                stub = commands / name
                stub.write_text(f'#!/bin/sh\necho "{name} $*"\n')
                stub.chmod(0o755)
            scripts = directory / 'scripts'
            scripts.mkdir()
            shutil.copy2(ROOT / 'scripts/pre-push.sh', scripts / 'pre-push.sh')
            source = directory / 'A.swift'
            source.write_text('let value = 1\n')
            readme = directory / 'README.md'
            readme.write_text('Before\n')
            env = {
                **os.environ, 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1',
                'PATH': f'{commands}:{os.environ["PATH"]}',
            }

            def git(*arguments):
                return subprocess.run(
                    ['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                     '-c', 'commit.gpgsign=false', *arguments],
                    cwd=directory, env=env, check=True, text=True, capture_output=True,
                )

            git('init')
            git('add', 'A.swift', 'README.md', 'scripts/pre-push.sh')
            git('commit', '-m', 'Initial fixture')
            base = git('rev-parse', 'HEAD').stdout.strip()
            source.write_text('let value = 2\n')
            readme.write_text('After\n')
            git('add', 'A.swift', 'README.md')
            git('commit', '-m', 'Mixed fixture changes')
            result = subprocess.run(
                ['bash', 'scripts/pre-push.sh', base], cwd=directory, env=env,
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('xcrun swift-format lint --strict -- A.swift', result.stdout)
            self.assertIn('swift build -Xswiftc -warnings-as-errors', result.stdout)
