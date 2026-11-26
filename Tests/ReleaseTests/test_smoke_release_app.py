from pathlib import Path
import os
import re
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/smoke-release-app.sh"
SWIFT = (ROOT / ".github/workflows/swift.yml").read_text()


def job_block(text, job):
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.S | re.M)
    if match is None:
        raise AssertionError(f"job {job} not found")
    return match.group(1)


class SmokeReleaseAppTests(unittest.TestCase):
    def run_smoke(self, body, timeout="5"):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "Mouthtype.app/Contents/MacOS/Mouthtype"
            exe.parent.mkdir(parents=True)
            exe.write_text("#!/bin/sh\n" + body + "\n")
            exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            codesign = fake_bin / "codesign"
            codesign.write_text("#!/bin/sh\nexit 0\n")
            codesign.chmod(0o755)
            env = dict(
                os.environ,
                PATH=f"{fake_bin}:{os.environ['PATH']}",
                MOUTHTYPE_BUILD_DIR=tmp,
                MOUTHTYPE_SMOKE_SKIP_BUILD="1",
                MOUTHTYPE_SMOKE_TIMEOUT=timeout,
            )
            return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def test_clean_exit_passes(self):
        self.assertEqual(self.run_smoke("exit 0").returncode, 0)

    def test_crash_fails(self):
        result = self.run_smoke("exit 3")
        self.assertEqual(result.returncode, 3)
        self.assertIn("status 3", result.stderr)

    def test_hang_is_killed_and_fails(self):
        result = self.run_smoke("sleep 30", timeout="2")
        self.assertEqual(result.returncode, 1)
        self.assertIn("still running", result.stderr)

    def test_launches_the_pill_demo(self):
        self.assertEqual(self.run_smoke('[ "$1" = --pill-demo ] || exit 9').returncode, 0)

    def test_swift_workflow_runs_it_and_the_receipt_waits_for_it(self):
        self.assertIn("scripts/smoke-release-app.sh", job_block(SWIFT, "bundle"))
        self.assertIn("bundle", re.search(r"needs: \[verify[^\]]*\]", job_block(SWIFT, "receipt")).group(0))


if __name__ == "__main__":
    unittest.main()
