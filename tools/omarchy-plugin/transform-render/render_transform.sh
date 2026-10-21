#!/usr/bin/env bash
# Render the Transform Selection panel (normal, AI ready, AI busy, refused, model missing, over the highlight cap, accepted,
# capture error) to PNG in light and dark on the NAS Docker testbed (offscreen Qt, software backend), and run the checks in
# tst_transform.qml. Reuses the image from design/render.
# Usage: bash tools/omarchy-plugin/transform-render/render_transform.sh <output-dir>
set -euo pipefail

out=${1:?Provide an output directory}
here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
mkdir -p "$out"
nas=(bash "$HOME/scripts/nas-docker.sh")
image=mouthtype-design-render:test
name=mouthtype-transform-render-$$

python3 "$here/make_fixtures.py" >/dev/null
"${nas[@]}" build -t "$image" "$plugin/design/render"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; "${nas[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
mkdir -p "$tmp/plugin/transform-render"
cp -R "$plugin/design" "$plugin/transform" "$tmp/plugin/"
rm -rf "$tmp/plugin/design/render" "$tmp/plugin/design/gallery"
cp "$here/tst_transform.qml" "$tmp/plugin/transform-render/"
# The scenes become a JS library so the harness needs no file reads.
python3 - "$plugin/transform/fixtures" "$tmp/plugin/transform-render/Fixtures.js" <<'PY'
import json, sys
from pathlib import Path
scenes = {path.stem: json.loads(path.read_text(encoding="utf-8")) for path in sorted(Path(sys.argv[1]).glob("*.json"))}
Path(sys.argv[2]).write_text(".pragma library\nvar scenes = " + json.dumps(scenes, ensure_ascii=False) + "\n", encoding="utf-8")
PY
cat > "$tmp/Dockerfile" <<'DOCKER'
FROM mouthtype-design-render:test
COPY plugin /work/plugin
DOCKER
"${nas[@]}" build -t "$image-transform" "$tmp"

"${nas[@]}" run --name "$name" "$image-transform" sh -c 'mkdir -p /tmp/mouthtype-transform && cd /work/plugin/transform-render && /usr/lib/qt6/bin/qmltestrunner -input tst_transform.qml' 2>&1 | tee "$out/harness.log" || true
"${nas[@]}" cp "$name:/tmp/mouthtype-transform/." "$out/"
grep -q 'Totals: .* 0 failed' "$out/harness.log" || { echo 'Transform checks reported failures.' >&2; exit 1; }
