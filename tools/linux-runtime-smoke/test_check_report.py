import copy
import unittest

import check_report


class SmokeReportTests(unittest.TestCase):
    def setUp(self):
        self.pins = {"sherpa": {"version": "1.13.8", "revision": "sherpa-revision"},
                     "llama": {"revision": "llama-revision"},
                     "parakeet": {"sha256": "archive"}, "s1": {"sha256": "s1-model"}}
        self.config = {"engines": {"speech": {"artifacts": {"encoder": {"sha256": "onnx"}}},
                                   "cleanup": {"artifacts": {"model": {"sha256": "s1-model"}, "server": {"sha256": "server"}}}}}
        self.cases = {"speech": ["speech-one", "speech-two", "silence"],
                      "cleanup": ["filler-01", "selfcorrect-01", "clean-01"]}
        self.report = {"execution_kind": "engine", "linux_runtime": True,
                       "environment": {"system": "Linux", "architecture": "x86_64"},
                       "engines": {
                           "speech": {"event": "ready", "runtime": "sherpa-onnx 1.13.8", "revision": "sherpa-revision",
                                      "artifacts": {"encoder": "onnx"}, "provenance": {"model": {"sha256": "archive"}}},
                           "cleanup": {"event": "ready", "runtime": "pinned llama", "revision": "llama-revision",
                                       "artifacts": {"model": "s1-model", "server": "server"}}},
                       "results": [{"task": task, "id": case, "status": "passed", "actual": "synthetic",
                                    "duration_ms": 10} for task, cases in self.cases.items() for case in cases]}

    def test_real_linux_completion_and_exact_success_are_distinct(self):
        result = check_report.assess(self.report, self.config, self.pins, self.cases, 0)
        self.assertTrue(result["runtime_completed"])
        self.assertTrue(result["accuracy_passed"])
        self.report["results"][0]["status"] = "mismatch"
        result = check_report.assess(self.report, self.config, self.pins, self.cases, 1)
        self.assertTrue(result["runtime_completed"])
        self.assertFalse(result["accuracy_passed"])

    def test_three_to_digit_counterexample_remains_an_exact_failure(self):
        case = next(row for row in self.report["results"] if row["id"] == "selfcorrect-01")
        case.update(status="mismatch", expected="Please send three copies.", actual="Please send 3 copies.")
        result = check_report.assess(self.report, self.config, self.pins, self.cases, 1)
        self.assertTrue(result["runtime_completed"])
        self.assertFalse(result["accuracy_passed"])
        self.assertEqual((result["passed"], result["mismatches"], result["total"]), (5, 1, 6))

    def test_fake_host_missing_results_bad_hashes_and_unavailable_are_rejected(self):
        mutations = [lambda r: r.update(execution_kind="test-double"),
                     lambda r: r.update(linux_runtime=False),
                     lambda r: r["results"].pop(),
                     lambda r: r["results"][0].update(status="unavailable"),
                     lambda r: r["engines"]["cleanup"]["artifacts"].update(model="other"),
                     lambda r: r["engines"]["speech"].update(revision="other"),
                     lambda r: r["results"].append(r["results"][0])]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                report = copy.deepcopy(self.report)
                mutate(report)
                result = check_report.assess(report, self.config, self.pins, self.cases, 0)
                self.assertFalse(result["runtime_completed"])
                self.assertTrue(result["problems"])


if __name__ == "__main__":
    unittest.main()
