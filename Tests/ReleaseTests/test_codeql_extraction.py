import importlib.util
from pathlib import Path
import tempfile
import unittest
import os
import subprocess


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/codeql/verify-extraction.py"
SPEC = importlib.util.spec_from_file_location("verify_extraction", SCRIPT)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


class ExtractionTests(unittest.TestCase):
    def test_scan_policy_uses_target_branch_and_event(self):
        workflow = SCRIPT.parents[2] / ".github/workflows/codeql.yml"
        text = workflow.read_text()
        run = text.split("        run: |\n", 1)[1].split("\n  analyze:", 1)[0]
        script = "\n".join(line[10:] for line in run.splitlines())
        cases = [
            ("pull_request", "dev/v0.8.0", "refs/pull/1/merge", "false"),
            ("pull_request", "main", "refs/pull/1/merge", "true"),
            ("push", "", "refs/heads/dev/v0.8.0", "false"),
            ("push", "", "refs/heads/main", "true"),
            ("schedule", "", "refs/heads/main", "true"),
            ("workflow_dispatch", "", "refs/heads/ci/codeql-efficiency", "true"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            for event, base, ref, expected in cases:
                with self.subTest(event=event, base=base):
                    output.write_text("")
                    subprocess.run(
                        ["bash", "-e", "-c", script],
                        env={**os.environ, "EVENT_NAME": event, "BASE_REF": base,
                             "REF": ref, "GITHUB_OUTPUT": str(output)},
                        check=True,
                    )
                    self.assertEqual(output.read_text(), f"swift={expected}\n")

    def test_schedule_and_push_have_separate_concurrency_groups(self):
        text = (SCRIPT.parents[2] / ".github/workflows/codeql.yml").read_text()
        group = next(line for line in text.splitlines() if line.startswith("  group:"))
        self.assertIn("github.event_name", group)
        self.assertIn("dev/v0.8.0", group)

    def test_non_scheduled_checkout_keeps_event_revision(self):
        text = (SCRIPT.parents[2] / ".github/workflows/codeql.yml").read_text()
        swift = text.split("  analyze-swift:", 1)[1]
        checkout_ref = next(line for line in swift.splitlines() if line.startswith("          ref:"))
        self.assertIn("|| github.sha", checkout_ref)
        self.assertIn("dev/v0.8.0", checkout_ref)

    def test_requires_every_first_party_file_including_fn_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["Mouthtype/main.swift", "mouthtype-fn-guard/main.swift"]:
                path = root / "Sources" / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("print(1)\n")
            report = root / "files.csv"
            report.write_text('"path"\n"Sources/Mouthtype/main.swift"\n')
            self.assertEqual(
                VERIFY.missing_sources(root, report),
                ["Sources/mouthtype-fn-guard/main.swift"],
            )
            with report.open("a") as output:
                output.write('"Sources/mouthtype-fn-guard/main.swift"\n')
            self.assertEqual(VERIFY.missing_sources(root, report), [])


if __name__ == "__main__":
    unittest.main()
