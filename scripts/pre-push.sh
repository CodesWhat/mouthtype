#!/usr/bin/env bash
# Opt-in pre-push checks: swift-format lint --strict on changed Swift files,
# then a warnings-as-errors build when any Swift file changed.
#
# Usage:
#   scripts/pre-push.sh [base-ref]   compare HEAD against base-ref (default origin/dev/v0.6.0,
#                                    falling back to origin/main)
#   scripts/pre-push.sh --stdin      read git's pre-push ref lines from stdin (used by the hook)
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

zero=0000000000000000000000000000000000000000
default_base() {
  for ref in origin/dev/v0.6.0 origin/main; do
    if git rev-parse --verify --quiet "$ref" >/dev/null; then
      echo "$ref"
      return
    fi
  done
}

files=()
add_range() {
  local range="$1"
  while IFS= read -r -d '' f; do
    [[ "$f" == *.swift && -f "$f" ]] && files+=("$f")
  done < <(git diff --name-only --diff-filter=ACMR -z "$range" --)
}

if [[ "${1:-}" == "--stdin" ]]; then
  while read -r _ local_sha _ remote_sha; do
    [[ "$local_sha" == "$zero" ]] && continue
    if [[ "$remote_sha" == "$zero" ]]; then
      base="$(default_base)"
      [[ -n "$base" ]] || { echo "pre-push: no base ref to diff against, skipping" >&2; exit 0; }
      remote_sha="$(git merge-base "$base" "$local_sha")"
    fi
    add_range "$remote_sha..$local_sha"
  done
else
  base="${1:-$(default_base)}"
  [[ -n "$base" ]] || { echo "pre-push: no base ref to diff against, skipping" >&2; exit 0; }
  add_range "$(git merge-base "$base" HEAD)..HEAD"
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "pre-push: no Swift files changed, skipping"
  exit 0
fi

# Dedupe while keeping order.
unique=()
while IFS= read -r f; do unique+=("$f"); done < <(printf '%s\n' "${files[@]}" | awk '!seen[$0]++')
files=("${unique[@]}")

echo "pre-push: swift-format lint --strict on ${#files[@]} file(s)"
xcrun swift-format lint --strict -- "${files[@]}"

echo "pre-push: swift build -Xswiftc -warnings-as-errors"
swift build -Xswiftc -warnings-as-errors
