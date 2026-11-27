from pathlib import Path
import re
import unittest


WORKFLOWS = Path(__file__).resolve().parents[2] / ".github/workflows"
PINNED = "CodesWhat/.github/actions/changes-gate@684a6b931e7802f1985e2cb4f6ea0c95861988e3"
FAIL_OPEN = (
    "if: ${{ !cancelled() && (needs.changes.result != 'success' || "
    "needs.changes.outputs.run != 'false') }}"
)
GATED_JOBS = {
    "docs-site.yml": ["docs-site"],
    "website.yml": ["website"],
}


def job_block(text, job):
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.S | re.M)
    if match is None:
        raise AssertionError(f"job {job} not found")
    return match.group(1)


class ChangesGateWorkflowTests(unittest.TestCase):
    def test_gate_is_pinned_to_the_reviewed_sha(self):
        for name in GATED_JOBS:
            with self.subTest(workflow=name):
                text = (WORKFLOWS / name).read_text()
                self.assertIn(PINNED, text)
                self.assertEqual(text.count("changes-gate@"), 1)

    def test_gated_jobs_fail_open(self):
        for name, jobs in GATED_JOBS.items():
            text = (WORKFLOWS / name).read_text()
            for job in jobs:
                with self.subTest(workflow=name, job=job):
                    block = job_block(text, job)
                    self.assertIn("needs: changes", block)
                    self.assertIn(FAIL_OPEN, block)


if __name__ == "__main__":
    unittest.main()
