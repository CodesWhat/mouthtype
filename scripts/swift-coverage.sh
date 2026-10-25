#!/bin/bash
set -euo pipefail

codecov_dir="$(dirname "$(swift test --show-codecov-path)")"
profdata="$codecov_dir/default.profdata"
test -f "$profdata" || { echo "no coverage profile at $profdata" >&2; exit 1; }

objects=()
while IFS= read -r bundle; do
    binary="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"
    [ -f "$binary" ] || { echo "missing test binary $binary" >&2; exit 1; }
    objects+=("$binary")
done < <(find "$(dirname "$codecov_dir")" -maxdepth 1 -name '*.xctest')
test "${#objects[@]}" -gt 0 || { echo "no .xctest bundles beside $codecov_dir" >&2; exit 1; }

arguments=("${objects[0]}")
for binary in "${objects[@]:1}"; do
    arguments+=("-object=$binary")
done
xcrun llvm-cov report "${arguments[@]}" -instr-profile="$profdata" \
    -ignore-filename-regex='(\.build|Tests)/' > coverage-report.txt
cat coverage-report.txt
total="$(awk '/^TOTAL/ {print $(NF-3)}' coverage-report.txt)"
[[ "$total" =~ ^[0-9]+\.[0-9]+%$ ]] || { echo "missing total line coverage" >&2; exit 1; }
echo "Total line coverage: $total"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "Total line coverage: $total" >> "$GITHUB_STEP_SUMMARY"
    echo "![Swift line coverage](https://img.shields.io/badge/Swift_line_coverage-${total%\%}%25-blue)" >> "$GITHUB_STEP_SUMMARY"
fi

read -r lines missed < <(awk '/^TOTAL/ {print $(NF-5), $(NF-4)}' coverage-report.txt)
[[ "$lines" =~ ^[0-9]+$ && "$missed" =~ ^[0-9]+$ ]] && (( lines > 0 && missed <= lines )) || {
    echo "invalid total line counts" >&2
    exit 1
}
if ! awk -v lines="$lines" -v missed="$missed" 'BEGIN {exit (100 * (lines - missed) < 80 * lines)}'; then
    echo "Swift line coverage is below the 80% floor ($((lines - missed))/$lines lines)." >&2
    exit 1
fi
