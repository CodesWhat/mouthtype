#!/usr/bin/env bash
# Run the Qt host tests offscreen and render the settings window in light and dark. Needs python3-pyside6.qtquick and the
# qml6 modules the pages import (Debian/Ubuntu names; Fedora has python3-pyside6 and qt6-qtdeclarative).
#   bash tools/linux-qt/run-tests.sh OUT_DIR
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:?Provide the output directory}
mkdir -p "$out"
out=$(cd "$out" && pwd)

export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software
cd "$repo"
timeout --kill-after=5s 300s python3 -W error::ResourceWarning -m unittest discover -v -s tools/linux-qt -p 'test_*.py' 2>&1 | tee "$out/host-tests.log"
for page in home general; do
  timeout --kill-after=5s 60s python3 tools/linux-qt/mouthtype_desktop.py --helper "$here/fixtures/control.py" --page "$page" --screenshot "$out/host-$page.png"
done
