#!/usr/bin/env bash
# Run the Qt host tests in a Debian trixie container on the NAS Docker testbed and copy the PNGs back.
#   bash tools/linux-qt/nas-run.sh OUT_DIR
set -euo pipefail

out=${1:?Provide the local output directory}
repo=$(cd "$(dirname "$0")/../.." && pwd)
nas="bash $HOME/scripts/nas-docker.sh"
image='debian:trixie@sha256:4c25275446ca371766b8b093c696782eabce06263fccacb8d5d813b3dc44b308'
name="${MOUTHTYPE_NAS_NAME:-linux-qt-$$}"
mkdir -p "$out"

source_path=$(cd "$repo" && $nas --sync .)
trap '$nas rm -f "$name" >/dev/null 2>&1 || true' EXIT

$nas create --name "$name" -v "$source_path:/src:ro" "$image" bash -c '
  set -euo pipefail
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install --yes --no-install-recommends python3 python3-pyside6.qtquick python3-pyside6.qtqml python3-pyside6.qtnetwork \
    qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-templates qml6-module-qtquick-window \
    qml6-module-qtquick-effects qml6-module-qtquick-layouts qml6-module-qtqml-workerscript qt6-svg-plugins fonts-dejavu-core procps
  useradd --create-home --shell /bin/bash qthost
  mkdir /out && chown qthost /out
  dpkg-query -W python3-pyside6.qtquick libqt6quick6 > /out/environment.txt
  runuser -u qthost -- bash /src/tools/linux-qt/run-tests.sh /out
' >/dev/null
$nas start -a "$name"
$nas cp "$name:/out/." "$out"
