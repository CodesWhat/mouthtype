from pathlib import Path
import re
import unittest


WORKFLOWS = Path(__file__).resolve().parents[2] / ".github/workflows"
SHA = "b85ebce168f649bcd2fddf2ff0d433fb38e30866"
VERIFY = f"CodesWhat/.github/actions/tree-receipt/verify@{SHA}"
RECORD = f"CodesWhat/.github/actions/tree-receipt/record@{SHA}"
CHANGES_GATE = (
    "(needs.changes.result != 'success' || needs.changes.outputs.run != 'false')"
)
FAIL_OPEN = (
    "(needs.verify.result != 'success' || needs.verify.outputs.reuse != 'true')"
)
REUSE_JOBS = ["build", "test"]


def job_block(text, job):
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.S | re.M)
    if match is None:
        raise AssertionError(f"job {job} not found")
    return match.group(1)


def job_if(block):
    match = re.search(r"^    if: (.*?)(?=^    [a-z-]+:|\Z)", block, re.S | re.M)
    if match is None:
        raise AssertionError("no job-level if")
    return " ".join(match.group(1).split())


class TreeReceiptWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.text = (WORKFLOWS / "swift.yml").read_text()

    def test_actions_are_pinned_to_the_reviewed_sha(self):
        self.assertEqual(self.text.count("tree-receipt/verify@"), 1)
        self.assertEqual(self.text.count("tree-receipt/record@"), 1)
        self.assertIn(VERIFY, self.text)
        self.assertIn(RECORD, self.text)

    def test_verify_checks_out_two_commits_without_credentials(self):
        block = job_block(self.text, "verify")
        self.assertIn("fetch-depth: 2", block)
        self.assertIn("persist-credentials: false", block)
        self.assertIn("statuses: read", block)
        self.assertNotIn("write", block)

    def test_expensive_jobs_fail_open_on_verify(self):
        for job in REUSE_JOBS:
            with self.subTest(job=job):
                block = job_block(self.text, job)
                self.assertIn("needs: [changes, verify]", block)
                condition = job_if(block)
                self.assertIn("!cancelled()", condition)
                self.assertIn(FAIL_OPEN, condition)
                self.assertIn(CHANGES_GATE, condition)

    def test_record_runs_only_after_build_and_test_succeed(self):
        block = job_block(self.text, "receipt")
        self.assertIn("needs: [verify, build, test]", block)
        self.assertIn("statuses: write", block)
        self.assertEqual(
            block.count("needs.build.result == 'success' && needs.test.result == 'success'"), 2
        )
        self.assertIn("[ \"$REUSE\" != true ]", block)

    def test_receipt_job_only_runs_on_push(self):
        block = job_block(self.text, "receipt")
        self.assertEqual(job_if(block), "${{ always() && github.event_name == 'push' }}")

    def test_status_write_is_limited_to_the_receipt_job(self):
        self.assertEqual(self.text.count("statuses: write"), 1)

    def test_other_workflows_do_not_use_reuse(self):
        for path in WORKFLOWS.glob("*.yml"):
            if path.name == "swift.yml":
                continue
            with self.subTest(workflow=path.name):
                self.assertNotIn("tree-receipt", path.read_text())


if __name__ == "__main__":
    unittest.main()
