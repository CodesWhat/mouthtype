#!/bin/bash
# Temporary CI diagnostic. Usage: scripts/ci-watchdog.sh <test-output-file> <out-dir> <stop-file>
out="$2"; mkdir -p "$out"
log="$out/system.log"
last_size=-1; last_change=$(date +%s); sampled=0
while [ ! -e "$3" ]; do
  {
    echo "=== $(date)"
    vm_stat | head -20
    memory_pressure -Q 2>&1 | tail -3
    sysctl vm.swapusage
    ps -Ao pid,pcpu,pmem,rss,comm -r | head -15
  } >> "$log" 2>&1
  size=$(stat -f %z "$1" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ "$size" != "$last_size" ]; then last_size=$size; last_change=$now; sampled=0; fi
  if [ $((now - last_change)) -ge 30 ] && [ "$sampled" -lt 3 ]; then
    sampled=$((sampled + 1))
    echo "=== stall ${sampled} at $(date), output idle $((now - last_change))s" >> "$log"
    for pid in $(pgrep -f 'xctest|swiftpm-testing-helper|swift-test|swift-build' | head -6); do
      comm=$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename)
      (sample "$pid" 5 -file "$out/sample-$(date +%H%M%S)-$pid-$comm.txt" >> "$log" 2>&1 \
        || spindump "$pid" 5 -file "$out/spindump-$pid.txt" >> "$log" 2>&1) &
    done
    wait
  fi
  sleep 20
done
