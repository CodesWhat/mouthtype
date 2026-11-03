#!/usr/bin/env bash
# Run the MouthtypePlatform contract tests against the scripted fake on the NAS Docker testbed (offscreen Qt, software backend).
# Reuses the image from design/render. Usage: bash tools/omarchy-plugin/design/render/render_platform.sh <output-dir>
set -euo pipefail

out=${1:?Provide an output directory}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
nas=(bash "$HOME/scripts/nas-docker.sh")
image=mouthtype-design-render:test
name=mouthtype-platform-test-$$

"${nas[@]}" build -t "$image" "$here"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; "${nas[@]}" rm -f "$name" >/dev/null 2>&1 || true' EXIT
mkdir -p "$tmp/platform"
cp -R "$here/fake/MouthtypePlatform" "$tmp/platform/MouthtypePlatform"
cp "$here/tst_platform.qml" "$tmp/platform/"
cat > "$tmp/Dockerfile" <<'DOCKER'
FROM mouthtype-design-render:test
COPY platform /work/platform
DOCKER
"${nas[@]}" build -t "$image-platform" "$tmp"

"${nas[@]}" run --name "$name" "$image-platform" sh -c 'cd /work/platform && /usr/lib/qt6/bin/qmltestrunner -import /work/platform -input tst_platform.qml' 2>&1 | tee "$out/harness.log" || true
grep -q 'Totals: .* 0 failed' "$out/harness.log" || { echo 'Platform checks reported failures.' >&2; exit 1; }
