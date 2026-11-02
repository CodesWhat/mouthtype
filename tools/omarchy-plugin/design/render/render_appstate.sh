#!/usr/bin/env bash
# Run the AppState tests against the scripted fake on the NAS Docker testbed (offscreen Qt, software backend).
# Reuses the image from design/render. Usage: bash tools/omarchy-plugin/design/render/render_appstate.sh <output-dir>
set -euo pipefail

out=${1:?Provide an output directory}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
nas=(bash "$HOME/scripts/nas-docker.sh")
image=mouthtype-design-render:test
name=mouthtype-appstate-test-$$

"${nas[@]}" build -t "$image" "$here"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; "${nas[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
plugin=$(cd "$here/../.." && pwd)
mkdir -p "$tmp/appstate"
cp -R "$here/fake/MouthtypePlatform" "$tmp/appstate/MouthtypePlatform"
cp "$here/tst_appstate.qml" "$plugin/AppState.qml" "$plugin/Fonts.js" "$tmp/appstate/"
cat > "$tmp/Dockerfile" <<'DOCKER'
FROM mouthtype-design-render:test
COPY appstate /work/appstate
DOCKER
"${nas[@]}" build -t "$image-appstate" "$tmp"

"${nas[@]}" run --name "$name" "$image-appstate" sh -c 'cd /work/appstate && /usr/lib/qt6/bin/qmltestrunner -import /work/appstate -input tst_appstate.qml' 2>&1 | tee "$out/harness.log" || true
grep -q 'Totals: .* 0 failed' "$out/harness.log" || { echo 'AppState checks reported failures.' >&2; exit 1; }
