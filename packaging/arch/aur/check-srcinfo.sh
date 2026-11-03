#!/usr/bin/env bash
# Fail when .SRCINFO is stale against PKGBUILD. Run as a normal user on Arch (makepkg refuses root), or in a
# container through test-aur.sh. MOUTHTYPE_BRANCH must be unset so the default branch is what gets recorded.
set -euo pipefail
cd "$(dirname "$0")"
unset MOUTHTYPE_BRANCH
fresh=$(mktemp)
trap 'rm -f "$fresh"' EXIT
makepkg --printsrcinfo > "$fresh"
if ! diff -u .SRCINFO "$fresh"; then
    echo "FAIL: .SRCINFO is stale. Regenerate: makepkg --printsrcinfo > .SRCINFO" >&2
    exit 1
fi
echo "ok: .SRCINFO matches PKGBUILD"
