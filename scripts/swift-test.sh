#!/bin/bash
# Runs `swift test` and fails on anything that reports a failure, not just on the exit status. SwiftPM exits non-zero for a
# failed test, but the status is lost the moment the run is piped (`swift test | tail`) and a test process that crashes before
# its summary prints can end without one. Extra arguments go to `swift test` (for example --filter).
# A stall watchdog samples and kills a run whose output stops growing for MOUTHTYPE_TEST_STALL_SECONDS (default 300, 0 disables),
# so a hung test fails fast with thread stacks instead of using up the CI job.
# Usage: scripts/swift-test.sh [swift test args]
set -uo pipefail

stall_seconds="${MOUTHTYPE_TEST_STALL_SECONDS:-300}"
case "$stall_seconds" in '' | *[!0-9]*) stall_seconds=300 ;; esac

workdir="$(mktemp -d -t swift-test.XXXXXX)"
log="$workdir/output.log"
stalled_flag="$workdir/stalled"
fifo="$workdir/output.fifo"
pidfile="$workdir/descendants"
: >"$log"
mkfifo "$fifo"

swift_pid=""
tee_pid=""
watchdog_pid=""

# Prints every descendant of a pid, children before their parents' later siblings, one per line.
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }

# Tests that printed "started" and never a pass or fail line. Parameterized cases and the run line are skipped.
unfinished_tests() {
  awk '
    /^◇ Test .* started\.$/ {
      n = $0; sub(/^◇ Test /, "", n); sub(/ started\.$/, "", n)
      if (n != "run" && n !~ /^case /) started[n] = ++order
    }
    /^[✔✘] Test .* (passed|failed) after / {
      n = $0; sub(/^[✔✘] Test /, "", n); sub(/ (passed|failed) after .*$/, "", n)
      delete started[n]
    }
    /^Test Case .* started\.$/ {
      n = $0; sub(/^Test Case /, "", n); sub(/ started\.$/, "", n); started[n] = ++order
    }
    /^Test Case .* (passed|failed)/ {
      n = $0; sub(/^Test Case /, "", n); sub(/ (passed|failed).*$/, "", n); delete started[n]
    }
    END { for (n in started) print started[n] "\t" n }
  ' "$1" | sort -n | cut -f2-
}

# Every descendant seen so far, as "pid<TAB>start time". Orphans reparent to launchd once swift test exits, so pgrep -P can no
# longer find them; the start time keeps a recycled pid from being mistaken for one of ours.
record_descendants() {
  local pid
  for pid in $(descendants "$swift_pid"); do
    grep -q "^$pid"$'\t' "$pidfile" 2>/dev/null || printf '%s\t%s\n' "$pid" "$(ps -o lstart= -p "$pid" 2>/dev/null)" >>"$pidfile"
  done
}

# Recorded pids that are still the same process.
recorded_pids() {
  local pid start
  [ -f "$pidfile" ] || return 0
  while IFS="$(printf '\t')" read -r pid start; do
    [ -n "$pid" ] && [ "$(ps -o lstart= -p "$pid" 2>/dev/null)" = "$start" ] && echo "$pid"
  done <"$pidfile"
}

# TERM everything we own (live descendants, recorded survivors, swift test, tee), KILL what is still up after a short grace.
stop_tree() {
  local pids="" pid alive
  if [ -n "$swift_pid" ] && kill -0 "$swift_pid" 2>/dev/null; then
    pids="$(descendants "$swift_pid" | sed '1!G;h;$!d') $swift_pid"
  fi
  pids="$pids $(recorded_pids) $tee_pid"
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null; done
  for _ in 1 2 3 4 5 6; do
    alive=0
    for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" -eq 0 ] && return 0
    sleep 0.5
  done
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null; done
}

watchdog() {
  local limit="$1" last_size current_size idle=0 pid victims sleeper=""
  trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; exit 0' TERM INT
  last_size="$(file_size "$log")"
  while kill -0 "$swift_pid" 2>/dev/null; do
    sleep 2 &
    sleeper=$!
    wait "$sleeper"
    sleeper=""
    record_descendants
    current_size="$(file_size "$log")"
    if [ "$current_size" != "$last_size" ]; then
      last_size="$current_size"
      idle=0
      continue
    fi
    idle=$((idle + 2))
    [ "$idle" -ge "$limit" ] || continue

    : >"$stalled_flag"
    victims="$( (descendants "$swift_pid"; recorded_pids) | awk '!seen[$0]++')"
    {
      echo
      echo "swift-test: no test output for $idle s, sampling and stopping"
      echo "swift-test: tests that started but never finished:"
      unfinished_tests "$log" | sed 's/^/  /'
      for pid in $victims; do
        echo "swift-test: sample of pid $pid ($(ps -o comm= -p "$pid" 2>/dev/null))"
        sample "$pid" 3 2>&1
      done
    } | tee -a "$log"
    # Deepest processes first, then the swift test process itself.
    for pid in $(echo "$victims" | sed '1!G;h;$!d'); do kill -TERM "$pid" 2>/dev/null; done
    kill -TERM "$swift_pid" 2>/dev/null
    sleep 5
    for pid in $victims "$swift_pid"; do kill -KILL "$pid" 2>/dev/null; done
    return 0
  done
}

cleanup() {
  trap - EXIT INT TERM
  if [ -n "$watchdog_pid" ]; then
    pkill -TERM -P "$watchdog_pid" 2>/dev/null
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
  fi
  stop_tree
  wait 2>/dev/null
  rm -rf "$workdir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tee "$log" <"$fifo" &
tee_pid=$!
swift test "$@" >"$fifo" 2>&1 &
swift_pid=$!

if [ "$stall_seconds" -gt 0 ]; then
  watchdog "$stall_seconds" &
  watchdog_pid=$!
fi

wait "$swift_pid"
status=$?

# Once stall termination has begun the watchdog owns the TERM/KILL escalation, so let it finish.
if [ -n "$watchdog_pid" ]; then
  if [ -e "$stalled_flag" ]; then
    wait "$watchdog_pid" 2>/dev/null
  else
    pkill -TERM -P "$watchdog_pid" 2>/dev/null
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
  fi
  watchdog_pid=""
fi

# A descendant that outlived swift test can keep the fifo open, so bound the drain.
drain_hung=0
for _ in $(seq 1 30); do
  kill -0 "$tee_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$tee_pid" 2>/dev/null; then
  drain_hung=1
  stop_tree
fi
wait "$tee_pid" 2>/dev/null

failed=0
complain() { echo "swift-test: $1" >&2; failed=1; }

[ "$drain_hung" -eq 0 ] || complain "test output did not close after swift test exited"
[ ! -e "$stalled_flag" ] || complain "test run stalled for $stall_seconds s"

[ "$status" -eq 0 ] || complain "swift test exited $status"
grep -q '^✘ ' "$log" && complain "a test or suite reported a failure"
grep -q 'Note: Some test targets reported failures' "$log" && complain "SwiftPM listed failing test targets"
grep -Eq 'with [1-9][0-9]* failures?' "$log" && complain "an XCTest run reported failures"

# Every Swift Testing run that starts must print its summary. A run that crashes mid-way never does.
started="$(grep -c 'Test run started' "$log")"
finished="$(grep -Ec '^[✔✘] Test run with ' "$log")"
[ "$started" -eq "$finished" ] || complain "$started Swift Testing runs started but $finished printed a summary"

exit "$failed"
