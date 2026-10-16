"""Compile and run canonical gesture logic/tests without the Apple/model dependency graph."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time


PACKAGE = '''// swift-tools-version:6.2
import PackageDescription
let package = Package(name: "MouthtypeCore", targets: [
    .target(name: "MouthtypeCore"),
    .testTarget(name: "MouthtypeCoreTests", dependencies: ["MouthtypeCore"]),
])
'''


def inspect_sources(root, manifest):
    root = Path(root).resolve()
    sources = sorted(str(path.relative_to(root)) for path in (root / "Sources/MouthtypeCore/Gesture").rglob("*.swift"))
    if sources != sorted(manifest["sources"]):
        raise ValueError("Gesture source inventory changed; review the canonical manifest")
    content = {path: (root / path).read_bytes() for path in sources}
    symbols = set()
    for raw in content.values():
        symbols.update(re.findall(r"^public (?:struct|enum|class) (\w+)", raw.decode(), re.MULTILINE))
    pattern = re.compile(r"\b(?:" + "|".join(re.escape(symbol) for symbol in symbols) + r")\b")
    tests = sorted(str(path.relative_to(root)) for path in (root / "Tests/MouthtypeCoreTests").rglob("*.swift")
                   if re.search(r"Gesture|HotKey|RecordingToggle", path.name) or pattern.search(path.read_text()))
    if tests != sorted(manifest["tests"]):
        raise ValueError("Gesture test inventory changed; review the canonical manifest")
    content.update({path: (root / path).read_bytes() for path in tests})
    if not sources or not tests:
        raise ValueError("Canonical inventory must contain sources and tests")
    for path, raw in content.items():
        imports = set(re.findall(r"^\s*(?:@testable\s+)?import\s+(\w+)", raw.decode(), re.MULTILINE))
        allowed = {"Foundation", "Testing", "MouthtypeCore"} if path in tests else {"Foundation"}
        if imports - allowed:
            raise ValueError(f"Unsupported import in {path}: {', '.join(sorted(imports - allowed))}")
    return content


def command_output(command, deadline):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=deadline)
        return process.returncode, output.decode(errors="replace")
    finally:
        process.poll()
        for action in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, action)
            except ProcessLookupError:
                pass
            except PermissionError:
                if process.poll() is None:
                    raise
                try:
                    os.killpg(process.pid, action)
                except ProcessLookupError:
                    pass
            if action == signal.SIGTERM:
                try:
                    process.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    pass
        process.wait(timeout=1)
        process.stdout.close()


def run_proof(root, manifest, swift="swift", temporary_parent=None, deadline_seconds=180):
    content = inspect_sources(root, manifest)
    declared = sum(len(re.findall(r"@Test\b", content[path].decode())) for path in manifest["tests"])
    if not declared:
        raise ValueError("Canonical tests contain no test declarations")
    result = {"schema": 1, "system": platform.system(), "architecture": platform.machine(),
              "linux_runtime": sys.platform == "linux", "scope": "pure-gesture-logic",
              "files": {path: hashlib.sha256(raw).hexdigest() for path, raw in content.items()},
              "declared_tests": declared, "executed_tests": 0, "status": "failed"}
    with tempfile.TemporaryDirectory(prefix="mouthtype-gesture-", dir=temporary_parent) as directory:
        package = Path(directory)
        (package / "Package.swift").write_text(PACKAGE)
        for group, destination in (("sources", "Sources/MouthtypeCore"), ("tests", "Tests/MouthtypeCoreTests")):
            target = package / destination
            target.mkdir(parents=True)
            names = set()
            for path in manifest[group]:
                name = Path(path).name
                if name in names:
                    raise ValueError("Canonical file names collide in the temporary package")
                names.add(name)
                (target / name).write_bytes(content[path])
        started = time.monotonic()
        try:
            code, version = command_output([swift, "--version"], min(10, deadline_seconds))
            if code:
                result["output"] = version
                return result
            result["swift_version"] = version.strip()
            code, output = command_output([swift, "test", "--jobs", "2", "--package-path", str(package)], deadline_seconds)
            result["output"] = output
            match = re.search(r"Test run with (\d+) tests?(?: in \d+ suites?)? passed", output)
            result["executed_tests"] = int(match.group(1)) if match else 0
            if code == 0 and result["executed_tests"] == declared:
                result["status"] = "passed"
        except subprocess.TimeoutExpired:
            result["status"] = "timed_out"
        except KeyboardInterrupt:
            result["status"] = "cancelled"
        except OSError as error:
            result["status"] = "unavailable"
            result["error_class"] = type(error).__name__
        finally:
            result["duration_seconds"] = time.monotonic() - started
    return result


def positive(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("Expected a finite positive deadline")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--receipt", required=True, type=Path, help="New JSON proof receipt")
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--deadline-seconds", type=positive, default=180)
    parser.add_argument("--require-linux", action="store_true")
    args = parser.parse_args()
    if args.require_linux and sys.platform != "linux":
        parser.error("This proof requires actual Linux execution")
    if args.receipt.exists():
        parser.error("Receipt already exists; choose a new path")
    manifest = json.loads(Path(__file__).with_name("canonical.json").read_text())

    def terminate(*_):
        raise KeyboardInterrupt

    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        result = run_proof(args.root, manifest, swift=args.swift, deadline_seconds=args.deadline_seconds)
        with args.receipt.open("x") as destination:
            json.dump(result, destination, indent=2)
            destination.write("\n")
        print(result.get("output", ""), end="")
        print(json.dumps({key: value for key, value in result.items() if key != "output"}, sort_keys=True))
        print(f"Gesture proof: {result['status']}; {result['executed_tests']}/{result['declared_tests']} canonical tests. Receipt: {args.receipt}")
        return 0 if result["status"] == "passed" else 1
    except (OSError, ValueError, KeyError) as error:
        print(f"Gesture proof unavailable: {error}", file=sys.stderr)
        return 2
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    sys.exit(main())
