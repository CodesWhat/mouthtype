#!/usr/bin/env bash
# Bring up the headless KDE session (as run.sh does) and run the kde-portal acceptance component inside it.
# Usage: acceptance.sh [output-dir]   (default /var/lib/testbed). Writes kde-portal.json next to kwin.log.
set -euo pipefail

if [[ "${1:-}" != --inner ]]; then
  out=${1:-${EVIDENCE_DIR:-/var/lib/testbed}}
  mkdir -p "$out"
  exec dbus-run-session -- "$0" --inner "$out"
fi

out=$2
APP_ID=${MOUTHTYPE_APP_ID:-app.mouthtype.Mouthtype}
acceptance=${MOUTHTYPE_ACCEPTANCE:-/opt/mouthtype/tools/linux-desktop/acceptance.py}
SOCKET=wayland-mouthtype
export WAYLAND_DISPLAY=$SOCKET
# Qt apps started below (the portal backend) export an accessibility tree, so the GlobalShortcuts consent dialog can be answered over AT-SPI.
export QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1

pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT

wait_for() { # description, timeout seconds, command...
  local what=$1 limit=$2; shift 2
  for _ in $(seq 1 $((limit * 5))); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "timed out waiting for $what" >&2
  return 1
}

kwin_wayland --virtual --width 1280 --height 800 --no-lockscreen --socket "$SOCKET" > "$out/kwin.log" 2>&1 &
pids+=($!)
wait_for 'kwin wayland socket' 30 test -S "$XDG_RUNTIME_DIR/$SOCKET" \
  || { tail -n 40 "$out/kwin.log" >&2; exit 1; }

/usr/libexec/xdg-desktop-portal-kde > "$out/portal-kde.log" 2>&1 &
pids+=($!)
/usr/libexec/xdg-desktop-portal -r > "$out/portal.log" 2>&1 &
pids+=($!)
wait_for 'portal frontend' 20 gdbus call --session --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop --method org.freedesktop.DBus.Peer.Ping

python3 /opt/testbed/seed-permission-store.py "$APP_ID" > "$out/permission-store.txt"
sleep 2

status=0
MOUTHTYPE_ACCEPTANCE_EVIDENCE="$out" python3 "$acceptance" kde-portal > "$out/kde-portal.json" || status=$?
cat "$out/kde-portal.json"
exit "$status"
