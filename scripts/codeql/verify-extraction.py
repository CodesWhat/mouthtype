#!/usr/bin/env python3
"""Check the finalized Swift database's source coverage."""

import csv
from pathlib import Path
import sys


def missing_sources(root, report):
    with report.open(newline="") as stream:
        extracted = {row[0] for row in csv.reader(stream) if row}
    expected = {path.relative_to(root).as_posix() for path in (root / "Sources").rglob("*.swift")}
    if not expected:
        raise ValueError("No first-party Swift sources found")
    return sorted(expected - extracted)


if __name__ == "__main__":
    missing = missing_sources(Path.cwd(), Path(sys.argv[1]))
    if missing:
        sys.exit("Swift files absent from CodeQL extraction:\n" + "\n".join(missing))
