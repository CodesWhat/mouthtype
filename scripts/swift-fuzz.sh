#!/bin/bash
# Fuzz the production phrase matcher. Extra libFuzzer flags, such as -runs=1000, pass through.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
output="${MOUTHTYPE_FUZZ_OUTPUT:-$root/build/fuzz}"
mkdir -p "$output/corpus" "$output/artifacts"
cp "$root"/Tests/Fuzzing/Corpus/* "$output/corpus/"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library -sanitize=fuzzer,address -g -O \
    "$root/Sources/MouthtypeCore/Text/TextScan.swift" \
    "$root/Sources/MouthtypeCore/Text/PhraseKey.swift" \
    "$root/Sources/MouthtypeCore/Text/PhraseMatcher.swift" \
    "$root/Tests/Fuzzing/PhraseMatcherFuzz.swift" \
    -o "$output/phrase-matcher"
exec "$output/phrase-matcher" "$output/corpus" \
    -max_total_time=30 -max_len=4096 -timeout=5 -rss_limit_mb=512 \
    "-artifact_prefix=$output/artifacts/" "$@"
