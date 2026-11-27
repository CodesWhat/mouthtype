import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/check-version-strings.py'
spec = importlib.util.spec_from_file_location('check_version_strings', SCRIPT)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def write(root, relative, text):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def fixture(root, version='1.2.3', build='9'):
    (root / 'packaging').mkdir()
    with (root / 'packaging/Version.plist').open('wb') as file:
        plistlib.dump({'MouthtypeDisplayVersion': version, 'CFBundleShortVersionString': version,
                       'CFBundleVersion': build}, file)
    write(root, 'website/package.json', json.dumps({'version': version}))
    write(root, 'README.md', f'<img src="https://img.shields.io/badge/version-{version}-2ea44f">\n')
    write(root, 'CHANGELOG.md', f'# Changelog\n\n## [Unreleased]\n\n## [{version}] - 2026-01-01\n')
    write(root, 'docs/RELEASE-READINESS.md',
          f'# Mac {version} release readiness\n\n- Stable {version} (build {build}) did things.\n')
    write(root, 'docs/READ-ME.md', f'# Mouthtype {version}\n')
    write(root, 'docs/KNOWN-LIMITS.md', f'# Known limits for {version}\n')
    write(root, 'website/vercel.json', json.dumps({'routes': [
        {'src': '/download/file', 'headers': {'Location': f'/releases/{version}/Mouthtype-{version}-macos-arm64.dmg'}},
        {'src': '/source', 'headers': {'Location': f'/releases/{version}/Mouthtype-{version}-source.tar.gz'}},
    ]}))


class VersionStringTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mouthtype-version-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        fixture(self.root)

    def test_agreeing_files_pass(self):
        self.assertEqual(check.problems(self.root), [])

    def test_stale_readiness_title_is_reported(self):
        write(self.root, 'docs/RELEASE-READINESS.md', '# Mac 1.2.2 release readiness\n\n- Stable 1.2.3 (build 9) x.\n')
        found = check.problems(self.root)
        self.assertEqual(len(found), 1)
        self.assertIn('RELEASE-READINESS.md', found[0])

    def test_missing_build_entry_and_stale_redirect_are_reported(self):
        write(self.root, 'docs/RELEASE-READINESS.md', '# Mac 1.2.3 release readiness\n\n- Stable 1.2.3 (build 8) x.\n')
        write(self.root, 'website/vercel.json', json.dumps({'routes': [
            {'src': '/download/file', 'headers': {'Location': '/releases/1.2.2/a.dmg'}},
            {'src': '/source', 'headers': {'Location': '/releases/1.2.3/a.tar.gz'}}]}))
        found = ' '.join(check.problems(self.root))
        self.assertIn('build 9', found)
        self.assertIn('/download/file', found)
        self.assertNotIn('/source', found)

    def test_changelog_and_package_and_badge_are_checked(self):
        write(self.root, 'CHANGELOG.md', '# Changelog\n\n## [Unreleased]\n\n## [1.2.2] - 2026-01-01\n')
        write(self.root, 'website/package.json', json.dumps({'version': '1.2.2'}))
        write(self.root, 'README.md', 'no badge\n')
        found = ' '.join(check.problems(self.root))
        for name in ('CHANGELOG.md', 'package.json', 'README.md'):
            self.assertIn(name, found)

    def test_this_repository_agrees(self):
        self.assertEqual(check.problems(ROOT), [])


if __name__ == '__main__':
    unittest.main()
