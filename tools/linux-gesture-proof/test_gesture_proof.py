import hashlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path
import tempfile
import sys
import unittest

import gesture_proof


FAKE_SWIFT = '''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys,time
if "--version" in sys.argv:
 print("Swift fake test runtime");sys.exit(0)
package=pathlib.Path(sys.argv[sys.argv.index("--package-path")+1])
pathlib.Path(__file__).with_suffix(".package").write_text(str(package))
assert ".package(" not in (package/"Package.swift").read_text()
assert (package/"Sources/MouthtypeCore/Gesture.swift").read_text()=="import Foundation\\npublic struct Gesture {}\\n"
{behavior}
'''


class GestureProofTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "Sources/MouthtypeCore/Gesture/Gesture.swift"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("import Foundation\npublic struct Gesture {}\n")
        self.test = self.root / "Tests/MouthtypeCoreTests/GestureTests.swift"
        self.test.parent.mkdir(parents=True)
        self.test.write_text("import Testing\n@testable import MouthtypeCore\n@Test func gestureWorks() { _ = Gesture() }\n")
        self.manifest = {"sources": [str(self.source.relative_to(self.root))],
                         "tests": [str(self.test.relative_to(self.root))]}
        self.temp_parent = self.root / "temporary"
        self.temp_parent.mkdir()

    def fake_swift(self, behavior):
        path = self.root / "swift-fake"
        path.write_text(FAKE_SWIFT.replace("{behavior}", behavior).replace("#!/usr/bin/env python3", "#!" + sys.executable))
        path.chmod(0o700)
        return str(path)

    def test_canonical_bytes_and_hashes_are_copied_into_dependency_free_temp_package(self):
        fake = self.fake_swift('print("Test run with 1 tests in 1 suites passed after 0.1 seconds.")')
        result = gesture_proof.run_proof(self.root, self.manifest, swift=fake, temporary_parent=self.temp_parent)
        self.assertEqual(result.get("status"), "passed")
        self.assertEqual(result["files"][self.manifest["sources"][0]], hashlib.sha256(self.source.read_bytes()).hexdigest())
        self.assertEqual(result["declared_tests"], 1)
        self.assertEqual(result["executed_tests"], 1)
        self.assertEqual(result["system"], os.uname().sysname)
        self.assertEqual(list(self.temp_parent.iterdir()), [])
        self.assertFalse(Path(Path(fake).with_suffix(".package").read_text()).exists())

    def test_new_or_missing_source_and_renamed_related_test_require_manifest_update(self):
        extra = self.source.with_name("NewGesture.swift")
        extra.write_text("public struct NewGesture {}")
        with self.assertRaisesRegex(ValueError, "inventory"):
            gesture_proof.inspect_sources(self.root, self.manifest)
        extra.unlink()
        self.source.unlink()
        with self.assertRaisesRegex(ValueError, "inventory"):
            gesture_proof.inspect_sources(self.root, self.manifest)
        self.source.write_text("import Foundation\npublic struct Gesture {}\n")
        extra_test = self.test.with_name("DifferentNameTests.swift")
        extra_test.write_text("@Test func newCheck() { _ = Gesture() }")
        with self.assertRaisesRegex(ValueError, "inventory"):
            gesture_proof.inspect_sources(self.root, self.manifest)

    def test_apple_dependency_is_rejected_before_swift_is_started(self):
        self.source.write_text("import AppKit\npublic struct Gesture {}\n")
        with self.assertRaisesRegex(ValueError, "import"):
            gesture_proof.inspect_sources(self.root, self.manifest)

    def test_failure_and_timeout_remove_the_generated_package(self):
        for behavior, expected in [('sys.exit(1)', 'failed'), ('time.sleep(20)', 'timed_out')]:
            with self.subTest(expected=expected):
                fake = self.fake_swift(behavior)
                result = gesture_proof.run_proof(self.root, self.manifest, swift=fake,
                                                temporary_parent=self.temp_parent, deadline_seconds=.3 if expected == "timed_out" else 2)
                self.assertEqual(result.get("status"), expected)
                self.assertEqual(list(self.temp_parent.iterdir()), [])

    def test_sigterm_cleans_temporary_package_and_active_build_descendant(self):
        fake = self.fake_swift('child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(20)"]); pathlib.Path(__file__).with_suffix(".pids").write_text(json.dumps([os.getpid(),child.pid])); time.sleep(20)')
        entry = self.root / "gesture_proof.py"
        entry.write_bytes(Path(gesture_proof.__file__).read_bytes())
        (self.root / "canonical.json").write_text(json.dumps(self.manifest))
        receipt = self.root / "receipt.json"
        process = subprocess.Popen([sys.executable, str(entry), "--root", str(self.root),
                                    "--swift", fake, "--receipt", str(receipt)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        pids = Path(fake).with_suffix(".pids")
        try:
            end = time.monotonic() + 3
            while not pids.exists() and time.monotonic() < end:
                time.sleep(.01)
            self.assertTrue(pids.exists(), "fake build did not start")
            process.terminate()
            self.assertEqual(process.wait(timeout=3), 1)
            self.assertEqual(json.loads(receipt.read_text())["status"], "cancelled")
            self.assertFalse(Path(Path(fake).with_suffix(".package").read_text()).exists())
            for pid in json.loads(pids.read_text()):
                for _ in range(20):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(.025)
                else:
                    details = {}
                    for observed in (pid, 1):
                        try:
                            lines = Path(f"/proc/{observed}/status").read_text().splitlines()
                            details[str(observed)] = {line.split(":", 1)[0]: line.split(":", 1)[1].strip()
                                                      for line in lines if line.startswith(("Name:", "State:", "PPid:", "NSpid:"))}
                        except OSError as error:
                            details[str(observed)] = type(error).__name__
                    self.fail("owned build descendant remained alive: " + json.dumps(details, sort_keys=True))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
            if pids.exists():
                try:
                    os.killpg(json.loads(pids.read_text())[0], signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_zero_tests_cannot_be_reported_as_success(self):
        fake = self.fake_swift('print("Test run with 0 tests passed after 0.1 seconds.")')
        result = gesture_proof.run_proof(self.root, self.manifest, swift=fake, temporary_parent=self.temp_parent)
        self.assertEqual(result.get("status"), "failed")


if __name__ == "__main__":
    unittest.main()
