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
rcfile=tools/linux-qt/.coveragerc
export COVERAGE_FILE="$out/.coverage"
timeout --kill-after=5s 300s python3 -W error::ResourceWarning -m coverage run --rcfile="$rcfile" -m unittest discover -v -s tools/linux-qt -p 'test_*.py' 2>&1 | tee "$out/host-tests.log"
python3 -m coverage report --rcfile="$rcfile" 2>&1 | tee "$out/host-coverage.txt"
for page in home general; do
  timeout --kill-after=5s 60s python3 tools/linux-qt/mouthtype_desktop.py --helper "$here/fixtures/control.py" --page "$page" --screenshot "$out/host-$page.png"
done
if compgen -G '/usr/lib/*/qt6/qml/org/kde/layershell/qmldir' >/dev/null; then
  timeout --kill-after=5s 60s python3 tools/linux-qt/mouthtype_desktop.py --helper "$here/fixtures/control.py" --force-pill \
    --launcher "$here/fixtures/mouthtype-linux" --pill-screenshot "$out/host-pill.png"
fi
