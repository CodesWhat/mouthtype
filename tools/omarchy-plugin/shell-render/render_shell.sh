#!/usr/bin/env bash
# Render every panel page and the Settings modal to PNG in light and dark on the NAS Docker testbed (offscreen Qt, software
# backend), and run the tests in tst_shell.qml. Reuses the image built by design/render.
# Usage: bash tools/omarchy-plugin/shell-render/render_shell.sh <output-dir>
set -euo pipefail

out=${1:?Provide an output directory}
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
mkdir -p "$out"
nas=(bash "$HOME/scripts/nas-docker.sh")
image=mouthtype-design-render:test
name=mouthtype-shell-render-$$

"${nas[@]}" build -t "$image" "$plugin/design/render"

# The plugin sources are copied into the container; the engine cannot see Mac paths.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; "${nas[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
mkdir "$tmp/plugin"
cp -R "$plugin/design" "$plugin/pages" "$plugin/parts" "$plugin/shell-render" "$plugin/Fonts.js" "$tmp/plugin/"
cp "$plugin"/Mouthtype*.qml "$tmp/plugin/"
rm -rf "$tmp/plugin/design/render" "$tmp/plugin/design/gallery"
cat > "$tmp/Dockerfile" <<'DOCKER'
FROM mouthtype-design-render:test
COPY plugin /work/plugin
DOCKER
"${nas[@]}" build -t "$image-shell" "$tmp"

  "${nas[@]}" run --name "$name" "$image-shell" sh -c 'mkdir -p /tmp/mouthtype-shell && cd /work/plugin/shell-render && QML_XHR_ALLOW_FILE_READ=1 /usr/lib/qt6/bin/qmltestrunner -input .' 2>&1 | tee "$out/harness.log" || true
"${nas[@]}" cp "$name:/tmp/mouthtype-shell/." "$out/"
grep -q 'Totals: .* 0 failed' "$out/harness.log" && ! grep 'Totals:' "$out/harness.log" | grep -qv ' 0 failed' || { echo 'Shell checks reported failures.' >&2; exit 1; }
