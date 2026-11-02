#!/usr/bin/env bash
# Run the render harness in an Arch container on the NAS Docker testbed and copy the PNGs back.
#   bash tools/qml-render/nas-run.sh OUT_DIR [case-name ...]
set -euo pipefail

out=${1:?Provide the local output directory}
shift
repo=$(cd "$(dirname "$0")/../.." && pwd)
nas="bash $HOME/scripts/nas-docker.sh"
image='archlinux:base-20261011.0.609700@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0'
name="qml-render-$$"
mkdir -p "$out"

source_path=$(cd "$repo" && $nas --sync .)
trap '$nas rm -f "$name" >/dev/null 2>&1 || true' EXIT

$nas create --name "$name" -v "$source_path:/src:ro" "$image" bash -c '
  set -euo pipefail
  pacman -Syu --disable-sandbox --noconfirm --needed qt6-declarative qt6-svg ttf-dejavu perl
  useradd --create-home --shell /bin/bash qmlrender
  mkdir /out && chown qmlrender /out
  runuser -u qmlrender -- bash /src/tools/qml-render/run.sh /out "$@"
' bash "$@" >/dev/null
$nas start -a "$name"
$nas cp "$name:/out/." "$out"
