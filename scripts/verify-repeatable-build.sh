#!/usr/bin/env bash
# Builds the unsigned app twice from clean clones of HEAD in two differently named directories,
# then compares a shasum of every file. Documented exceptions: Assets.car (actool output differs
# run to run) and code signatures. Exits 0 when nothing else differs.
#   scripts/verify-repeatable-build.sh [--keep]
#
# Only committed content is built (git clone of HEAD), so commit changes first. Slow: two full
# release builds, each fetching dependencies. Does not sign, notarize or touch secrets.
# See docs/REPEATABLE-BUILD.md.

set -euo pipefail
cd "$(dirname "$0")/.."

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

REPO="$PWD"
HEAD_SHA="$(git rev-parse HEAD)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mouthtype-repeatable.XXXXXX")"
cleanup() { rm -rf "$SCRATCH"; [ "$KEEP" = 1 ] && echo "kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

# Same scratch path for both: dependency source paths end up in the binary, so it must not vary.
# Cleared first so each run starts from a clean build.
SCRATCH="/private/tmp/mouthtype-repeatable-scratch"

# Different directory names on purpose: the build must not depend on either.
DIRS=("$WORK/mouthtype" "$WORK/another-name.checkout")
for i in 0 1; do
    git clone -q --no-hardlinks "$REPO" "${DIRS[$i]}"
    git -C "${DIRS[$i]}" checkout -q "$HEAD_SHA"
    rm -rf "$SCRATCH"
    echo "→ build $((i + 1)) in ${DIRS[$i]}"
    (cd "${DIRS[$i]}" && MOUTHTYPE_UNSIGNED=1 MOUTHTYPE_SCRATCH_PATH="$SCRATCH" MOUTHTYPE_BUILD_DIR="$WORK/out-$i" scripts/build-app.sh >"$WORK/build-$i.log" 2>&1) \
        || { tail -30 "$WORK/build-$i.log" >&2; echo "build $((i + 1)) failed" >&2; KEEP=1; exit 2; }
done

manifest() { (cd "$1/Mouthtype.app" && find . -type f -o -type l | LC_ALL=C sort | while read -r f; do
    if [ -L "$f" ]; then echo "link:$(readlink "$f")  $f"; else echo "$(shasum -a 256 "$f" | cut -d' ' -f1)  $f"; fi
done); }
manifest "$WORK/out-0" >"$WORK/m0.txt"
manifest "$WORK/out-1" >"$WORK/m1.txt"
echo "files per build: $(wc -l <"$WORK/m0.txt" | tr -d ' ')"

# Mach-O files compare equal once the (linker ad-hoc) signature is removed: signature-only diffs.
unsigned_sha() { local t; t="$(mktemp "$WORK/sig.XXXXXX")"; cp "$1" "$t"
    codesign --remove-signature "$t" 2>/dev/null || true; shasum -a 256 "$t" | cut -d' ' -f1; rm -f "$t"; }

BAD=0
DIFFS="$({ diff <(cat "$WORK/m0.txt") <(cat "$WORK/m1.txt") | sed -n 's/^[<>] .*  \(.*\)$/\1/p' || true; } | sort -u)"
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in
        */Assets.car) echo "exception (actool nondeterminism): $f"; continue ;;
    esac
    if file "$WORK/out-0/Mouthtype.app/$f" | grep -q Mach-O \
        && [ "$(unsigned_sha "$WORK/out-0/Mouthtype.app/$f")" = "$(unsigned_sha "$WORK/out-1/Mouthtype.app/$f")" ]; then
        echo "exception (code signature only): $f"; continue
    fi
    echo "DIFF: $f ($(cmp -l "$WORK/out-0/Mouthtype.app/$f" "$WORK/out-1/Mouthtype.app/$f" 2>/dev/null | wc -l | tr -d ' ') bytes differ)"
    BAD=1
done <<<"$DIFFS"

if [ "$BAD" = 0 ]; then echo "repeatable: all files match except the documented exceptions"; else echo "NOT repeatable" >&2; KEEP=1; exit 1; fi
