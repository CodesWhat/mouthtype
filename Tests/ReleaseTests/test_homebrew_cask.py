import hashlib
import subprocess
import unittest
from pathlib import Path
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/generate-homebrew-cask.sh"


def run(*args):
    return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True)


class HomebrewCaskTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.dmg = self.dir / "Mouthtype.dmg"
        self.dmg.write_bytes(b"fake dmg bytes")
        self.digest = hashlib.sha256(b"fake dmg bytes").hexdigest()

    def test_prints_cask_with_version_and_local_dmg_digest(self):
        result = run("--version", "1.2.3", "--dmg", str(self.dmg))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('cask "mouthtype" do', result.stdout)
        self.assertIn('version "1.2.3"', result.stdout)
        self.assertIn(f'sha256 "{self.digest}"', result.stdout)
        self.assertIn("depends_on macos: :tahoe", result.stdout)
        self.assertIn("v#{version}/Mouthtype-#{version}-macos-arm64.dmg", result.stdout)

    def test_write_creates_file_without_leftover_temp(self):
        out = self.dir / "mouthtype.rb"
        result = run("--version", "1.2.3", "--dmg", str(self.dmg), "--write", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'sha256 "{self.digest}"', out.read_text())
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["Mouthtype.dmg", "mouthtype.rb"])

    def test_rejects_malformed_versions(self):
        for bad in ("v1.2.3", "1.2", "1.2.3-rc1", '1.2.3"'):
            result = run("--version", bad, "--dmg", str(self.dmg))
            self.assertEqual(result.returncode, 65, bad)
            self.assertEqual(result.stdout, "")

    def test_missing_dmg_fails(self):
        result = run("--version", "1.2.3", "--dmg", str(self.dir / "nope.dmg"))
        self.assertEqual(result.returncode, 66)

    def test_write_over_the_dmg_is_refused(self):
        result = run("--version", "1.2.3", "--dmg", str(self.dmg), "--write", str(self.dmg))
        self.assertEqual(result.returncode, 67)
        self.assertEqual(self.dmg.read_bytes(), b"fake dmg bytes")

    def test_unknown_flag_prints_usage(self):
        self.assertEqual(run("--bogus").returncode, 64)


if __name__ == "__main__":
    unittest.main()
