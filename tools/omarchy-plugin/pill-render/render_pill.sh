#!/usr/bin/env bash
# Render the pill states and delivery cards to PNG in light and dark on the NAS Docker testbed (offscreen Qt, software backend).
# Reuses the image from design/render. Usage: bash tools/omarchy-plugin/pill-render/render_pill.sh <output-dir>
set -euo pipefail

out=${1:?Provide an output directory}
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
mkdir -p "$out"
nas=(bash "$HOME/scripts/nas-docker.sh")
image=mouthtype-design-render:test
name=mouthtype-pill-render-$$

"${nas[@]}" build -t "$image" "$plugin/design/render"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; "${nas[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
mkdir -p "$tmp/plugin"
cp -R "$plugin/design" "$tmp/plugin/design"
rm -rf "$tmp/plugin/design/render"
cp "$plugin/ClassicPill.qml" "$plugin/PillCard.qml" "$plugin/PillCardButton.qml" "$plugin/CardPalette.js" "$plugin/PillModel.js" "$tmp/plugin/"
mkdir -p "$tmp/plugin/pill-render"
cp "$here/PillSheet.qml" "$here/tst_pill.qml" "$tmp/plugin/pill-render/"
cat > "$tmp/Dockerfile" <<'DOCKER'
FROM mouthtype-design-render:test
COPY plugin /work/plugin
DOCKER
"${nas[@]}" build -t "$image-pill" "$tmp"

"${nas[@]}" run --name "$name" "$image-pill" sh -c 'cd /work/plugin/pill-render && /usr/lib/qt6/bin/qmltestrunner -input tst_pill.qml' 2>&1 | tee "$out/harness.log" || true
for mode in light dark; do
  "${nas[@]}" cp "$name:/tmp/mouthtype-pill-$mode.png" "$out/pill-$mode.png"
done
grep -q 'Totals: .* 0 failed' "$out/harness.log" || { echo 'Pill checks reported failures.' >&2; exit 1; }
