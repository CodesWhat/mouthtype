#!/bin/bash
# Runs `swift test` and fails on anything that reports a failure, not just on the exit status. SwiftPM exits non-zero for a
# failed test, but the status is lost the moment the run is piped (`swift test | tail`) and a test process that crashes before
# its summary prints can end without one. Extra arguments go to `swift test` (for example --filter).
# Usage: scripts/swift-test.sh [swift test args]
set -uo pipefail

log="$(mktemp -t swift-test.XXXXXX)"
trap 'rm -f "$log"' EXIT

swift test "$@" 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"

failed=0
complain() { echo "swift-test: $1" >&2; failed=1; }

[ "$status" -eq 0 ] || complain "swift test exited $status"
grep -q '^✘ ' "$log" && complain "a test or suite reported a failure"
grep -q 'Note: Some test targets reported failures' "$log" && complain "SwiftPM listed failing test targets"
grep -Eq 'with [1-9][0-9]* failures?' "$log" && complain "an XCTest run reported failures"

# Every Swift Testing run that starts must print its summary. A run that crashes mid-way never does.
started="$(grep -c 'Test run started' "$log")"
finished="$(grep -Ec '^[✔✘] Test run with ' "$log")"
[ "$started" -eq "$finished" ] || complain "$started Swift Testing runs started but $finished printed a summary"

exit "$failed"
