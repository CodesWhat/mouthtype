#!/usr/bin/env bash
# Builds the release bundle the way a release does (ad-hoc signed when no Developer ID is in the keychain) and launches
# its own executable in the pill demo, which needs no permissions and quits when the walk-through ends. A bundle that
# fails to assemble, fails codesign verification, or crashes or hangs at launch fails here instead of after the tag.
#   scripts/smoke-release-app.sh
#   MOUTHTYPE_SMOKE_TIMEOUT   seconds to wait for the demo to exit (default 120)
#   MOUTHTYPE_SMOKE_SKIP_BUILD=1  launch the bundle already in MOUTHTYPE_BUILD_DIR (default build)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${MOUTHTYPE_BUILD_DIR:-build}"
APP="$OUT/Mouthtype.app"
LIMIT="${MOUTHTYPE_SMOKE_TIMEOUT:-120}"
case "$LIMIT" in '' | *[!0-9]*) echo "MOUTHTYPE_SMOKE_TIMEOUT must be whole seconds" >&2; exit 2 ;; esac

if [ "${MOUTHTYPE_SMOKE_SKIP_BUILD:-}" != 1 ]; then
    MOUTHTYPE_TIMESTAMP=none bash scripts/build-app.sh
fi
codesign --verify --deep --strict "$APP"

"$APP/Contents/MacOS/Mouthtype" --pill-demo &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$LIMIT" ]; then
        echo "release bundle still running after ${LIMIT}s; killing it" >&2
        kill -9 "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 1
    fi
    sleep 1
    waited=$((waited + 1))
done
status=0
wait "$pid" || status=$?
if [ "$status" -ne 0 ]; then
    echo "release bundle exited with status $status" >&2
    exit "$status"
fi
echo "release bundle launched and exited cleanly after ${waited}s"
