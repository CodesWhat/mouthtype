"""Assess real-runtime completion separately from unchanged exact quality checks."""

import argparse
import json
import math
import os
from pathlib import Path
import sys


def assess(report, config, pins, cases, proof_exit):
    problems = []
    if report.get("execution_kind") != "engine" or report.get("linux_runtime") is not True:
        problems.append("not-real-linux-engines")
    environment = report.get("environment", {})
    if environment.get("system") != "Linux" or environment.get("architecture") != "x86_64":
        problems.append("unexpected-host")
    for task, runtime in (("speech", "sherpa"), ("cleanup", "llama")):
        engine = report.get("engines", {}).get(task, {})
        expected = {name: value["sha256"] for name, value in config["engines"][task]["artifacts"].items()}
        if engine.get("event") != "ready" or engine.get("revision") != pins[runtime]["revision"]:
            problems.append(task + "-not-ready-or-unpinned")
        if engine.get("artifacts") != expected:
            problems.append(task + "-artifact-mismatch")
    speech = report.get("engines", {}).get("speech", {})
    cleanup = report.get("engines", {}).get("cleanup", {})
    if speech.get("runtime") != "sherpa-onnx " + pins["sherpa"]["version"]:
        problems.append("sherpa-version")
    if speech.get("provenance", {}).get("model", {}).get("sha256") != pins["parakeet"]["sha256"]:
        problems.append("parakeet-provenance")
    if cleanup.get("artifacts", {}).get("model") != pins["s1"]["sha256"]:
        problems.append("s1-provenance")
    expected_cases = sorted((task, case) for task, values in cases.items() for case in values)
    records = report.get("results", [])
    if sorted((row.get("task", ""), row.get("id", "")) for row in records) != expected_cases:
        problems.append("missing-duplicate-or-unexpected-cases")
    for row in records:
        elapsed = row.get("duration_ms")
        if row.get("status") not in ("passed", "mismatch") or not isinstance(row.get("actual"), str):
            problems.append(str(row.get("id")) + "-incomplete")
        if not isinstance(elapsed, (float, int)) or not math.isfinite(elapsed) or elapsed < 0:
            problems.append(str(row.get("id")) + "-no-completion-timing")
    if proof_exit not in (0, 1):
        problems.append("proof-command-failed")
    complete = not problems
    accurate = complete and proof_exit == 0 and all(row["status"] == "passed" for row in records)
    return {"runtime_completed": complete, "accuracy_passed": accurate, "problems": problems,
            "passed": sum(row.get("status") == "passed" for row in records),
            "mismatches": sum(row.get("status") == "mismatch" for row in records), "total": len(records)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    parser.add_argument("--proof-exit", required=True, type=int)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    report = json.loads(args.report.read_text())
    config = json.loads(args.config.read_text())
    pins = json.loads((root / "tools/linux-engine-proof/pins.json").read_text())
    fixtures = json.loads(args.fixtures.read_text())
    cases = {task: [case["id"] for case in values] for task, values in fixtures.items()}
    summary = assess(report, config, pins, cases, args.proof_exit)
    owned = {row["worker_pid"] for row in report.get("results", []) if row.get("worker_pid")}
    server = report.get("engines", {}).get("cleanup", {}).get("server_pid")
    if server:
        owned.add(server)
    surviving = []
    for pid in owned:
        try:
            os.kill(pid, 0)
            surviving.append(pid)
        except ProcessLookupError:
            pass
    if surviving:
        summary["problems"].append("owned-processes-remain")
        summary["runtime_completed"] = False
        summary["accuracy_passed"] = False
    summary["remaining_owned_pids"] = surviving
    print(json.dumps({"real_runtime_assessment": summary}, indent=2))
    return 0 if summary["accuracy_passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
