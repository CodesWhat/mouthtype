#!/usr/bin/env bash
# Builds Mouthtype.app and opens it. Always launch through `open`, never the
# binary directly: privacy grants would attach to the terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

MOUTHTYPE_TIMESTAMP=none bash scripts/build-app.sh "$@"
open "${MOUTHTYPE_BUILD_DIR:-build}/Mouthtype.app"
