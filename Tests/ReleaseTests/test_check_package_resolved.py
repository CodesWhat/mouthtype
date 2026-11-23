import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/check-package-resolved.py'
spec = importlib.util.spec_from_file_location('check_package_resolved', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

FLUID_0_18_3 = ('0.18.3', 'c8b41f98eae668794dd0083bbe028fe7e6585051')
FLUID_0_18_0 = ('0.18.0', 'e15287985625dbf544a343df679436789ffb03fb')
GRDB = ('7.12.0', '92a554cd0d5e8d67cb18993c6054e73fe42c066c')


def resolved(**states):
    pins = [{'identity': identity, 'kind': 'remoteSourceControl',
             'location': f'https://github.com/example/{identity}',
             'state': {'revision': revision, 'version': version}}
            for identity, (version, revision) in states.items()]
    return json.dumps({'originHash': 'f' * 64, 'pins': pins, 'version': 3}, indent=2)


class CompareTests(unittest.TestCase):
    def test_unchanged_file_passes(self):
        text = resolved(fluidaudio=FLUID_0_18_3, grdb=GRDB)
        self.assertEqual(guard.check(text, text, False, False), [])

    def test_real_fluidaudio_downgrade_fails_and_names_both_versions(self):
        old = resolved(fluidaudio=FLUID_0_18_3, grdb=GRDB)
        new = resolved(fluidaudio=FLUID_0_18_0, grdb=GRDB)
        for dependency_change in (False, True):
            failures = '\n'.join(guard.check(old, new, dependency_change, False))
            self.assertIn('moves a pin backwards', failures)
            self.assertIn('fluidaudio: 0.18.3 (c8b41f98eae6) -> 0.18.0 (e15287985625) [downgrade]', failures)
            self.assertNotIn('grdb', failures)

    def test_revision_change_under_the_same_version_fails(self):
        old = resolved(grdb=GRDB)
        new = resolved(grdb=('7.12.0', 'a' * 40))
        failures = '\n'.join(guard.check(old, new, True, False))
        self.assertIn('grdb: 7.12.0 (92a554cd0d5e) -> 7.12.0 (aaaaaaaaaaaa) [revision changed under the same version]', failures)

    def test_upgrade_outside_a_dependency_change_fails(self):
        old = resolved(fluidaudio=FLUID_0_18_0)
        new = resolved(fluidaudio=FLUID_0_18_3)
        failures = '\n'.join(guard.check(old, new, False, False))
        self.assertIn('not a dependency change', failures)
        self.assertIn('fluidaudio: 0.18.0 (e15287985625) -> 0.18.3 (c8b41f98eae6)', failures)
        self.assertNotIn('backwards', failures)

    def test_upgrade_in_a_dependency_change_passes(self):
        old = resolved(fluidaudio=FLUID_0_18_0)
        new = resolved(fluidaudio=FLUID_0_18_3)
        self.assertEqual(guard.check(old, new, True, False), [])

    def test_downgrade_with_allow_downgrade_passes_only_in_a_dependency_change(self):
        old = resolved(fluidaudio=FLUID_0_18_3)
        new = resolved(fluidaudio=FLUID_0_18_0)
        self.assertEqual(guard.check(old, new, True, True), [])
        failures = '\n'.join(guard.check(old, new, False, True))
        self.assertIn('not a dependency change', failures)
        self.assertNotIn('backwards', failures)

    def test_added_package_passes_in_a_dependency_change_only(self):
        old = resolved(grdb=GRDB)
        new = resolved(grdb=GRDB, fluidaudio=FLUID_0_18_3)
        self.assertEqual(guard.check(old, new, True, False), [])
        self.assertIn('fluidaudio: added at 0.18.3 (c8b41f98eae6)', '\n'.join(guard.check(old, new, False, False)))

    def test_removed_package_and_deleted_file_need_a_dependency_change(self):
        old = resolved(grdb=GRDB, fluidaudio=FLUID_0_18_3)
        self.assertEqual(guard.check(old, resolved(grdb=GRDB), True, False), [])
        for new in (resolved(grdb=GRDB), None):
            self.assertIn('fluidaudio: removed, was 0.18.3 (c8b41f98eae6)', '\n'.join(guard.check(old, new, False, False)))

    def test_missing_file_at_the_base_passes(self):
        self.assertEqual(guard.check(None, resolved(fluidaudio=FLUID_0_18_3), False, False), [])
        self.assertEqual(guard.check(None, None, False, False), [])

    def test_origin_hash_only_change_needs_a_dependency_change(self):
        old = resolved(grdb=GRDB)
        new = old.replace('f' * 64, 'e' * 64)
        self.assertEqual(guard.check(old, new, True, False), [])
        self.assertIn('without a pin change', '\n'.join(guard.check(old, new, False, False)))

    def test_branch_pin_moving_is_a_change_but_not_a_downgrade(self):
        old = resolved(tool=(None, 'a' * 40))
        new = resolved(tool=(None, 'b' * 40))
        self.assertEqual(guard.check(old, new, True, False), [])
        self.assertIn('tool: no version (aaaaaaaaaaaa) -> no version (bbbbbbbbbbbb)', '\n'.join(guard.check(old, new, False, False)))

    def test_versions_compare_by_semver_precedence(self):
        ordered = ['0.9.10', '0.18.0', '0.18.3', '1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta',
                   '1.0.0-beta.2', '1.0.0-beta.11', '1.0.0-rc.1', '1.0.0', '1.0.1', '2.0.0', '10.0.0']
        keys = [guard.version_key(version) for version in ordered]
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(len(set(keys)), len(keys))
        self.assertEqual(guard.version_key('v1.2.3+build.5'), guard.version_key('1.2.3'))
        with self.assertRaisesRegex(ValueError, 'Not a semantic version'):
            guard.version_key('1.2')

    def test_duplicate_pins_are_rejected(self):
        text = json.dumps({'pins': [{'identity': 'a', 'state': {}}, {'identity': 'a', 'state': {}}]})
        with self.assertRaisesRegex(ValueError, 'Duplicate pin'):
            guard.pins(text)

    def test_dependency_change_signals(self):
        self.assertFalse(guard.is_dependency_change(False, 'feat/website-analytics', {'enhancement'}))
        self.assertTrue(guard.is_dependency_change(True, 'feat/website-analytics', set()))
        self.assertTrue(guard.is_dependency_change(False, 'dependabot/swift/fluidaudio-0.18.3', set()))
        self.assertTrue(guard.is_dependency_change(False, 'deps/fluidaudio', set()))
        self.assertFalse(guard.is_dependency_change(False, 'feat/deps/cleanup', set()))
        self.assertTrue(guard.is_dependency_change(False, 'chore/pins', {'dependencies'}))

    def test_labels_parse_from_json_or_commas(self):
        self.assertEqual(guard.parse_labels('["Dependencies", "swift"]'), {'dependencies', 'swift'})
        self.assertEqual(guard.parse_labels('dependencies, downgrade,'), {'dependencies', 'downgrade'})
        self.assertEqual(guard.parse_labels('[]'), set())
        self.assertEqual(guard.parse_labels(''), set())
        self.assertEqual(guard.parse_labels(None), set())


class RepositoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        os.chdir(self.directory)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith('GIT_')}
        self.commits = 0
        self.git('init', '--quiet', '--initial-branch=base')
        self.commit({'Package.swift': '// one\n', 'Package.resolved': resolved(fluidaudio=FLUID_0_18_3, grdb=GRDB)})
        self.git('switch', '--quiet', '--create', 'work')

    def git(self, *arguments):
        subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                        '-c', 'commit.gpgsign=false', *arguments],
                       check=True, capture_output=True, env=self.environment)

    def commit(self, files, remove=()):
        for name, text in files.items():
            (self.directory / name).write_text(text)
        for name in remove:
            (self.directory / name).unlink()
        self.git('add', '--all')
        # Number the messages so identical trees committed in the same second get distinct commits.
        self.commits += 1
        self.git('commit', '--quiet', '--allow-empty', '--message', f'change {self.commits}')

    def run_guard(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = guard.main(['--base', 'base', *arguments])
        return status, output.getvalue(), errors.getvalue()

    def test_unrelated_change_passes(self):
        self.commit({'README.md': 'notes\n'})
        status, output, _ = self.run_guard('--branch', 'feat/notes')
        self.assertEqual(status, 0)
        self.assertIn('Package.resolved check passed', output)

    def test_downgrade_in_a_feature_branch_fails_on_both_counts(self):
        self.commit({'Package.resolved': resolved(fluidaudio=FLUID_0_18_0, grdb=GRDB)})
        status, _, errors = self.run_guard('--branch', 'feat/website-analytics', '--labels', '["enhancement"]')
        self.assertEqual(status, 1)
        self.assertIn('fluidaudio: 0.18.3 (c8b41f98eae6) -> 0.18.0 (e15287985625) [downgrade]', errors)
        self.assertIn('not a dependency change', errors)

    def test_downgrade_needs_the_flag_or_label_even_in_a_dependency_branch(self):
        self.commit({'Package.resolved': resolved(fluidaudio=FLUID_0_18_0, grdb=GRDB)})
        self.assertEqual(self.run_guard('--branch', 'deps/fluidaudio')[0], 1)
        self.assertEqual(self.run_guard('--branch', 'deps/fluidaudio', '--allow-downgrade')[0], 0)
        self.assertEqual(self.run_guard('--branch', 'chore/pins', '--labels', '["dependencies","downgrade"]')[0], 0)

    def test_manifest_change_makes_an_upgrade_a_dependency_change(self):
        self.commit({'Package.resolved': resolved(fluidaudio=FLUID_0_18_3, grdb=('7.13.0', 'c' * 40))})
        self.assertEqual(self.run_guard('--branch', 'feat/database')[0], 1)
        self.commit({'Package.swift': '// two\n'})
        self.assertEqual(self.run_guard('--branch', 'feat/database')[0], 0)

    def test_base_moving_ahead_is_not_blamed_on_the_branch(self):
        self.commit({'README.md': 'notes\n'})
        self.git('switch', '--quiet', 'base')
        self.commit({'Package.resolved': resolved(fluidaudio=('0.19.0', 'd' * 40), grdb=GRDB)})
        self.git('switch', '--quiet', 'work')
        self.assertEqual(self.run_guard('--branch', 'feat/notes')[0], 0)

    def test_file_missing_at_the_base_or_the_head(self):
        self.git('switch', '--quiet', 'base')
        self.commit({}, remove=['Package.resolved'])
        self.git('switch', '--quiet', '--create', 'fresh')
        self.commit({'Package.resolved': resolved(grdb=GRDB)})
        self.assertEqual(self.run_guard('--branch', 'feat/first-package')[0], 0)
        self.git('switch', '--quiet', 'work')
        self.commit({}, remove=['Package.resolved'])
        status, _, errors = self.run_guard('--branch', 'feat/cleanup')
        self.assertEqual(status, 1)
        self.assertIn('grdb: removed, was 7.12.0 (92a554cd0d5e)', errors)

    def test_base_is_required(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            guard.main([])


if __name__ == '__main__':
    unittest.main()
