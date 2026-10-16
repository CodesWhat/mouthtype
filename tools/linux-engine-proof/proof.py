"""Run supplied non-sensitive fixtures against resident, isolated CPU engines."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time


class Stopped(Exception):
    pass


def digest(path):
    result = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def verify_artifacts(config):
    result = {}
    for name, artifact in config["artifacts"].items():
        actual = digest(artifact["path"])
        if actual != artifact["sha256"]:
            raise ValueError(f"SHA-256 mismatch for {name}")
        result[name] = actual
    return result


def load_cases(path, task):
    cases = json.loads(Path(path).read_text())
    if not isinstance(cases, list) or not cases:
        raise ValueError("Fixture file must contain a non-empty array")
    seen = set()
    result = []
    for item in cases:
        if not isinstance(item, dict):
            raise ValueError("Each fixture must be an object")
        case = dict(item)
        if "expected" not in case and "reference" in case:
            case["expected"] = case["reference"]
        if not isinstance(case.get("id"), str) or not case["id"] or case["id"] in seen:
            raise ValueError("Fixture IDs must be non-empty and unique")
        seen.add(case["id"])
        if not isinstance(case.get("expected"), str):
            raise ValueError("Each fixture needs expected or reference text, including empty text")
        field = "wav" if task == "speech" else "input"
        if not isinstance(case.get(field), str):
            raise ValueError(f"Each {task} fixture needs {field}")
        if task == "speech":
            case["wav"] = str((Path(path).resolve().parent / case["wav"]).resolve())
            case["audio_sha256"] = digest(case["wav"])
        for key in ("mustContain", "mustNotContain"):
            if key in case and (not isinstance(case[key], list) or
                                any(not isinstance(x, str) for x in case[key])):
                raise ValueError(f"Invalid fixture {key}")
        if "maxLengthRatio" in case and (not isinstance(case["maxLengthRatio"], (int, float)) or
                                         not math.isfinite(case["maxLengthRatio"]) or case["maxLengthRatio"] <= 0):
            raise ValueError("Invalid maxLengthRatio")
        result.append(case)
    return result


class Worker:
    def __init__(self, command):
        self.errors = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=self.errors, start_new_session=True)
        except BaseException:
            self.errors.close()
            raise
        os.set_blocking(self.process.stdin.fileno(), False)
        self.writer = selectors.DefaultSelector()
        self.writer.register(self.process.stdin, selectors.EVENT_WRITE)
        self.reader = selectors.DefaultSelector()
        self.reader.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""

    def send(self, value, seconds, cancelled):
        raw = json.dumps(value, ensure_ascii=False).encode() + b"\n"
        if len(raw) > 1024 * 1024:
            raise ValueError("Fixture request exceeds 1 MiB")
        end = time.monotonic() + seconds
        offset = 0
        while offset < len(raw):
            if cancelled.is_set():
                raise Stopped("cancelled")
            if time.monotonic() >= end:
                raise Stopped("deadline")
            if self.writer.select(min(.05, max(0, end - time.monotonic()))):
                try:
                    offset += os.write(self.process.stdin.fileno(), raw[offset:])
                except BlockingIOError:
                    continue
        return max(0, end - time.monotonic())

    def receive(self, seconds, cancelled):
        end = time.monotonic() + seconds
        while True:
            if cancelled.is_set():
                raise Stopped("cancelled")
            if time.monotonic() >= end:
                raise Stopped("deadline")
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                response = json.loads(line)
                if not isinstance(response, dict):
                    raise ValueError("Invalid worker response")
                return response
            if self.reader.select(min(.05, max(0, end - time.monotonic()))):
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise ValueError("Engine worker exited before completing its response")
                self.buffer += data
                if len(self.buffer) > 2 * 1024 * 1024:
                    raise ValueError("Engine response exceeds 2 MiB")

    def close(self):
        # Reap an already-exited leader before signalling its group. Darwin can report
        # EPERM for an unreaped group with no living members.
        self.process.poll()
        for action in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(self.process.pid, action)
            except ProcessLookupError:
                pass
            except PermissionError:
                if self.process.poll() is None:
                    raise
                try:
                    os.killpg(self.process.pid, action)
                except ProcessLookupError:
                    pass
            if action == signal.SIGTERM:
                try:
                    self.process.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    pass
        self.process.wait(timeout=1)
        self.reader.close()
        self.writer.close()
        self.process.stdin.close()
        self.process.stdout.close()
        self.errors.close()


def compare(case, text):
    failures = []
    if text != case["expected"]:
        failures.append("exact")
    folded = text.casefold()
    for value in case.get("mustContain", []):
        if value.casefold() not in folded:
            failures.append("missing:" + value)
    for value in case.get("mustNotContain", []):
        if value.casefold() in folded:
            failures.append("forbidden:" + value)
    if "maxLengthRatio" in case and len(text) > len(case.get("input", "")) * case["maxLengthRatio"]:
        failures.append("length")
    return failures


def environment():
    release = {}
    try:
        release = platform.freedesktop_os_release()
    except OSError:
        pass
    return {"system": platform.system(), "architecture": platform.machine(),
            "kernel": platform.release(), "python": platform.python_version(),
            "distribution": {k: release[k] for k in ("ID", "VERSION_ID", "PRETTY_NAME") if k in release}}


def run_suite(config, suites, *, command_for=None, startup_seconds=120, request_seconds=30, cancelled=None):
    cancelled = cancelled or threading.Event()
    report = {"schema": 1, "environment": environment(), "engines": {}, "results": [],
              "execution_kind": "test-double" if command_for else "engine",
              "linux_runtime": sys.platform == "linux",
              "comparison": "raw-engine-exact-reference", "mac_pipeline_parity": False}
    for task, cases in suites.items():
        settings = config["engines"][task]
        hashes = verify_artifacts(settings)
        worker = None
        unavailable = False
        ready = False
        loaded = {}
        try:
            if cancelled.is_set():
                raise Stopped("cancelled")
            command = command_for(task, settings) if command_for else [sys.executable, str(Path(__file__).with_name("worker.py")), task]
            worker = Worker(command)
            remaining = worker.send({"configuration": settings}, startup_seconds, cancelled)
            loaded = worker.receive(remaining, cancelled)
            if loaded.get("event") != "ready":
                raise ValueError("Engine failed to become ready")
            ready = True
            report["engines"][task] = {**loaded, "artifacts": hashes,
                                       "provenance": settings.get("provenance", {})}
        except Stopped as error:
            failure = "startup_deadline" if str(error) == "deadline" else str(error)
            unavailable = True
        except (OSError, ValueError, KeyError, TypeError):
            failure = "unavailable"
            unavailable = True
        try:
            for index, case in enumerate(cases):
                identity = json.dumps(case, sort_keys=True, ensure_ascii=False).encode()
                record = {"task": task, "id": case["id"], "expected": case["expected"],
                          "fixture_sha256": hashlib.sha256(identity).hexdigest(),
                          "worker_pid": worker.process.pid if worker else None, "resident_request": index + 1}
                if unavailable:
                    record["status"] = failure if index == 0 else "unavailable"
                else:
                    start = time.monotonic()
                    try:
                        remaining = worker.send(case, request_seconds, cancelled)
                        result = worker.receive(remaining, cancelled)
                        if result.get("event") == "error":
                            record["error_class"] = result.get("error_class", "EngineError")
                        if result.get("id") != case["id"] or not isinstance(result.get("text"), str):
                            raise ValueError("Invalid or mismatched engine result")
                        record.update(actual=result["text"], peak_rss_bytes=result.get("peak_rss_bytes"),
                                      duration_ms=(time.monotonic() - start) * 1000,
                                      first_output_ms=None, worker_peak_rss_bytes=result.get("worker_peak_rss_bytes"),
                                      server_peak_rss_bytes=result.get("server_peak_rss_bytes"))
                        record["failures"] = compare(case, result["text"])
                        record["status"] = "mismatch" if record["failures"] else "passed"
                    except Stopped as error:
                        record["status"] = str(error)
                        unavailable = True
                    except (OSError, ValueError, KeyError, TypeError):
                        record["status"] = "error"
                        unavailable = True
                report["results"].append(record)
        finally:
            if worker:
                worker.close()
        if not ready:
            report["engines"][task] = {"status": failure, "artifacts": hashes,
                                         "error_class": loaded.get("error_class")}
    return report


def positive(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("Must be a finite positive number")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--cleanup", type=Path, help="JSON cleanup fixtures, expected or existing reference field")
    parser.add_argument("--speech", type=Path, help="JSON speech fixtures with 16 kHz mono PCM16 WAV paths")
    parser.add_argument("--output", required=True, type=Path, help="New private JSON result file, includes full output text")
    parser.add_argument("--startup-seconds", type=positive, default=120)
    parser.add_argument("--request-seconds", type=positive, default=30)
    parser.add_argument("--cancel-after-seconds", type=positive)
    args = parser.parse_args()
    if not args.cleanup and not args.speech:
        parser.error("Supply --cleanup, --speech, or both")
    if args.output.exists():
        parser.error("Output already exists; choose a new private path")
    cancelled = threading.Event()
    old_handler = signal.signal(signal.SIGINT, lambda *_: cancelled.set())
    old_termination = signal.signal(signal.SIGTERM, lambda *_: cancelled.set())
    timer = None
    if args.cancel_after_seconds:
        timer = threading.Timer(args.cancel_after_seconds, cancelled.set)
        timer.start()
    try:
        config = json.loads(args.config.read_text())
        suites = {task: load_cases(path, task) for task, path in (("speech", args.speech), ("cleanup", args.cleanup)) if path}
        report = run_suite(config, suites, startup_seconds=args.startup_seconds,
                           request_seconds=args.request_seconds, cancelled=cancelled)
        with args.output.open("x") as destination:
            json.dump(report, destination, indent=2, ensure_ascii=False)
            destination.write("\n")
        total = len(report["results"])
        passed = sum(row["status"] == "passed" for row in report["results"])
        print(f"{passed}/{total} exact fixture checks passed. Private report: {args.output}")
        return 0 if passed == total else 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Proof unavailable: {type(error).__name__}. Check local config, tools and artifact hashes.", file=sys.stderr)
        return 2
    finally:
        signal.signal(signal.SIGINT, old_handler)
        signal.signal(signal.SIGTERM, old_termination)
        if timer:
            timer.cancel()
            timer.join()


if __name__ == "__main__":
    sys.exit(main())
