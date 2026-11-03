#!/usr/bin/env bash
# Run test-aur.sh in a disposable archlinux container on the NAS Docker testbed (never local Docker).
# Stages this checkout with the helper's --sync, runs one uniquely named container with --rm, and removes
# it on exit. No compose, no volumes, no prune: the only resource is the named container.
#
#   bash packaging/arch/aur/nas-test.sh
#
# MOUTHTYPE_AUR_IMAGE overrides the image (default archlinux:latest, the rolling tag AUR users build on).
set -euo pipefail

helper=${NAS_DOCKER:-$HOME/scripts/nas-docker.sh}
[ -f "$helper" ] || { echo "missing $helper (NAS Docker helper); not falling back to local Docker" >&2; exit 2; }
repo=$(cd "$(dirname "$0")/../../.." && pwd)
image=${MOUTHTYPE_AUR_IMAGE:-archlinux:latest}
name="mouthtype-aur-test-$$"

workspace=$(bash "$helper" --sync "$repo")
cleanup() { bash "$helper" rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

bash "$helper" run --rm --name "$name" --label dev.scttbnsn.task=mouthtype-aur-test \
    -v "$workspace":/repo:ro -e MOUTHTYPE_REPO=/repo \
    "$image" bash /repo/packaging/arch/aur/test-aur.sh
