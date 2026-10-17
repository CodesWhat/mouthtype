#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" == 0 || "$(uname -s)" != Linux ]]; then
  echo 'Run Linux component checks as the dedicated ordinary CI user.' >&2
  exit 2
fi

evidence=${1:?Provide the new CI evidence directory}
ci_status=0
python3 tools/linux-desktop/acceptance.py capabilities > "$evidence/capabilities.json"
if ! timeout --kill-after=5s 60s python3 -W error::ResourceWarning -m unittest discover -s tools/linux-desktop -p 'test_*.py' > "$evidence/desktop-tests.log" 2>&1; then
  ci_status=1
fi
if ! timeout --kill-after=5s 60s python3 -W error::ResourceWarning -m unittest discover -s tools/linux-engine-proof -p 'test_*.py' > "$evidence/engine-tests.log" 2>&1; then
  ci_status=1
fi
if ! timeout --kill-after=5s 60s dbus-run-session -- python3 tools/linux-desktop/acceptance.py pipewire > "$evidence/pipewire.json" 2> "$evidence/pipewire.log"; then
  ci_status=1
fi
if ! timeout --kill-after=5s 60s dbus-run-session -- python3 tools/linux-desktop/acceptance.py sway > "$evidence/sway.json" 2> "$evidence/sway.log"; then
  ci_status=1
fi
cat "$evidence/capabilities.json" "$evidence/desktop-tests.log" "$evidence/engine-tests.log" "$evidence/pipewire.json" "$evidence/pipewire.log" "$evidence/sway.json" "$evidence/sway.log"
exit "$ci_status"
