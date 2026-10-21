#!/usr/bin/env bash
# Render the design gallery to PNG in light and dark on the NAS Docker testbed (offscreen Qt, software backend).
# Usage: bash tools/omarchy-plugin/design/render/render_gallery.sh <output-dir>
set -euo pipefail

out=${1:?Provide an output directory}
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/../.." && pwd)
mkdir -p "$out"
nas=(bash "$HOME/scripts/nas-docker.sh")
image=mouthtype-design-render:test
name=mouthtype-design-render-$$

"${nas[@]}" build -t "$image" "$here"

# The design dir is copied into the container; the engine cannot see Mac paths.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; "${nas[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
cp -R "$plugin/design" "$tmp/design"
rm -rf "$tmp/design/render"
cat > "$tmp/Dockerfile" <<'DOCKER'
FROM mouthtype-design-render:test
COPY design /work/design
DOCKER
"${nas[@]}" build -t "$image-run" "$tmp"

"${nas[@]}" run --name "$name" "$image-run" sh -c 'cd /work/design/gallery && /usr/lib/qt6/bin/qmltestrunner -input tst_gallery.qml' 2>&1 | tee "$out/harness.log" || true
for mode in light dark; do
  "${nas[@]}" cp "$name:/tmp/mouthtype-gallery-$mode.png" "$out/gallery-$mode.png"
done
grep -q 'Totals: .* 0 failed' "$out/harness.log" || { echo 'Gallery checks reported failures.' >&2; exit 1; }
