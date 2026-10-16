import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time
import unittest

import proof


FAKE = r'''
import json,os,subprocess,sys,time
mode=sys.argv[1]
json.loads(sys.stdin.readline())
if mode=="startup": time.sleep(10)
print(json.dumps({"event":"ready","runtime":"fake","load_ms":3}),flush=True)
if mode=="backpressure": time.sleep(30)
for line in sys.stdin:
 case=json.loads(line)
 if mode=="crash": sys.exit(7)
 if mode=="hang":
  child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(30)"])
  open(sys.argv[2],"w").write(str(child.pid))
  time.sleep(30)
 if mode=="wrong": case["id"]="wrong"
 print(json.dumps({"id":case["id"],"text":case.get("input", ""),"peak_rss_bytes":12}),flush=True)
'''


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.fake = self.path / "fake.py"
        self.fake.write_text(FAKE)
        self.config = {"engines": {"cleanup": {"artifacts": {}}}}

    def run_cases(self, cases, mode="echo", **kw):
        return proof.run_suite(self.config, {"cleanup": cases},
            command_for=lambda task, config: [sys.executable, str(self.fake), mode, str(self.path / "child.pid")],
            startup_seconds=.3, request_seconds=.15, **kw)

    def test_resident_worker_returns_full_exact_results_and_records_environment(self):
        result = self.run_cases([
            {"id": "unicode", "input": "Send Sean’s mock-ups.", "expected": "Send Sean’s mock-ups."},
            {"id": "silence", "input": "", "expected": ""},
            {"id": "mismatch", "input": "dusting", "expected": "testing"},
        ])
        self.assertEqual([r["status"] for r in result["results"]], ["passed", "passed", "mismatch"])
        self.assertEqual(len({r["worker_pid"] for r in result["results"]}), 1)
        self.assertEqual(result["results"][0]["actual"], "Send Sean’s mock-ups.")
        self.assertEqual(result["environment"]["system"], os.uname().sysname)
        self.assertEqual(result["results"][1]["peak_rss_bytes"], 12)
        self.assertIn("fixture_sha256", result["results"][0])
        self.assertEqual(result["engines"]["cleanup"]["runtime"], "fake")

    def test_deadline_kills_worker_and_descendant_and_does_not_run_next_case(self):
        start = time.monotonic()
        result = self.run_cases([{"id": "slow", "input": "x", "expected": "x"},
                                 {"id": "later", "input": "x", "expected": "x"}], "hang")
        self.assertLess(time.monotonic() - start, 2)
        self.assertEqual([r["status"] for r in result["results"]], ["deadline", "unavailable"])
        pid = int((self.path / "child.pid").read_text())
        for _ in range(20):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.025)
        else:
            self.fail("engine descendant remained alive")

    def test_cancel_is_distinct_from_timeout_and_bounded(self):
        cancelled = threading.Event()
        timer = threading.Timer(.08, cancelled.set)
        timer.start()
        self.addCleanup(timer.join)
        result = self.run_cases([{"id": "cancel", "input": "x", "expected": "x"}], "hang", cancelled=cancelled)
        self.assertEqual([r["status"] for r in result["results"]], ["cancelled"])

    def test_pipe_backpressure_obeys_deadline(self):
        def alarm(*_):
            raise TimeoutError("outer test safeguard")
        previous = signal.signal(signal.SIGALRM, alarm)
        signal.setitimer(signal.ITIMER_REAL, .6)
        try:
            result = self.run_cases([{"id": "large", "input": "x" * 500000, "expected": "x"}], "backpressure")
            self.assertEqual([r["status"] for r in result["results"]], ["deadline"])
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)

    def test_startup_deadline_is_distinct_from_request_deadline(self):
        result = self.run_cases([{"id": "one", "input": "x", "expected": "x"}], "startup")
        self.assertEqual([r["status"] for r in result["results"]], ["startup_deadline"])

    def test_crash_and_mismatched_response_are_errors(self):
        for mode in ["crash", "wrong"]:
            with self.subTest(mode=mode):
                result = self.run_cases([{"id": "one", "input": "x", "expected": "x"}], mode)
                self.assertEqual([r["status"] for r in result["results"]], ["error"])

    def test_artifact_mismatch_is_rejected_before_any_worker_is_started(self):
        asset = self.path / "model.bin"
        asset.write_bytes(b"weights")
        config = {"artifacts": {"model": {"path": str(asset), "sha256": "0" * 64}}}
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            proof.verify_artifacts(config)
        config["artifacts"]["model"]["sha256"] = hashlib.sha256(b"weights").hexdigest()
        self.assertEqual(proof.verify_artifacts(config)["model"], config["artifacts"]["model"]["sha256"])

    def test_cleanup_benchmark_import_retains_constraints_and_empty_reference(self):
        path = self.path / "cases.json"
        path.write_text(json.dumps([{"id": "filler", "input": "um", "reference": "",
                                     "mustNotContain": ["um"], "maxLengthRatio": 1}]))
        cases = proof.load_cases(path, "cleanup")
        self.assertEqual(len(cases), 1)
        self.assertEqual(cases[0]["expected"], "")
        self.assertEqual(cases[0]["mustNotContain"], ["um"])

    def test_duplicate_case_ids_and_invalid_cases_are_rejected(self):
        path = self.path / "cases.json"
        for cases in [[{"id": "a", "input": "a", "expected": "a"}] * 2,
                      [{"id": "a", "input": "a"}], []]:
            path.write_text(json.dumps(cases))
            with self.assertRaises(ValueError):
                proof.load_cases(path, "cleanup")


if __name__ == "__main__":
    unittest.main()
