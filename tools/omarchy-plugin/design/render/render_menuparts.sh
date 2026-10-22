#!/usr/bin/env bash
# Load the menu parts (ControlButton, MenuRow, MenuDivider) in the plain render image, with no Quickshell, on the NAS Docker testbed.
# Reuses the image from design/render. Usage: bash tools/omarchy-plugin/design/render/render_menuparts.sh <output-dir>
set -euo pipefail

out=${1:?Provide an output directory}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
nas=(bash "$HOME/scripts/nas-docker.sh")
image=mouthtype-design-render:test
name=${MOUTHTYPE_RENDER_NAME:-mouthtype-menuparts-test-$$}

"${nas[@]}" build -t "$image" "$here"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; "${nas[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
plugin=$(cd "$here/../.." && pwd)
mkdir -p "$tmp/menuparts"
cp -R "$plugin/design" "$tmp/menuparts/design"
rm -rf "$tmp/menuparts/design/render"
cp "$here/tst_menuparts.qml" "$plugin/ControlButton.qml" "$plugin/MenuRow.qml" "$plugin/MenuDivider.qml" "$plugin/MenuStyle.qml" "$tmp/menuparts/"
cat > "$tmp/Dockerfile" <<'DOCKER'
FROM mouthtype-design-render:test
COPY menuparts /work/menuparts
DOCKER
"${nas[@]}" build -t "$image-menuparts" "$tmp"

"${nas[@]}" run --name "$name" "$image-menuparts" sh -c 'cd /work/menuparts && /usr/lib/qt6/bin/qmltestrunner -input tst_menuparts.qml' 2>&1 | tee "$out/harness.log" || true
grep -q 'Totals: .* 0 failed' "$out/harness.log" || { echo 'Menu part checks reported failures.' >&2; exit 1; }
