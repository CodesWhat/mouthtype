#!/usr/bin/env bash
# Bring up a headless KDE Plasma Wayland session and write evidence JSON.
# Evidence goes to $EVIDENCE_DIR (default /var/lib/testbed): versions.json, probe.json, kwin.log.
set -euo pipefail

if [[ -z "${MOUTHTYPE_KDE_INNER:-}" ]]; then
  export MOUTHTYPE_KDE_INNER=1
  exec dbus-run-session -- "$0" "$@"
fi

APP_ID=${MOUTHTYPE_APP_ID:-app.mouthtype.Mouthtype}
EVIDENCE_DIR=${EVIDENCE_DIR:-/var/lib/testbed}
SOCKET=wayland-mouthtype
mkdir -p "$EVIDENCE_DIR"
export WAYLAND_DISPLAY=$SOCKET

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

kwin_wayland --virtual --width 1280 --height 800 --no-lockscreen --socket "$SOCKET" \
  > "$EVIDENCE_DIR/kwin.log" 2>&1 &
pids+=($!)
wait_for 'kwin wayland socket' 30 test -S "$XDG_RUNTIME_DIR/$SOCKET"

# Portal frontend and the KDE backend are D-Bus activated, but start the backend
# explicitly so a failure shows up in its own log.
/usr/libexec/xdg-desktop-portal-kde > "$EVIDENCE_DIR/portal-kde.log" 2>&1 &
pids+=($!)
/usr/libexec/xdg-desktop-portal -r > "$EVIDENCE_DIR/portal.log" 2>&1 &
pids+=($!)
wait_for 'portal frontend' 20 gdbus call --session --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop --method org.freedesktop.DBus.Peer.Ping

python3 /opt/testbed/seed-permission-store.py "$APP_ID" > "$EVIDENCE_DIR/permission-store.txt"

rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' | sort \
  | grep -E '^(kwin|plasma-workspace|xdg-desktop-portal|layer-shell-qt|pipewire|wireplumber|at-spi2-core|python3-jeepney|gtk3|qt6-qtbase|qt6-qtdeclarative|fedora-release) ' \
  | python3 -c '
import json, sys
pkgs = dict(line.split(" ", 1) for line in sys.stdin.read().splitlines())
print(json.dumps({"os": "fedora-44-kde", "packages": pkgs}, indent=2, sort_keys=True))
' > "$EVIDENCE_DIR/versions.json"

probe=/opt/mouthtype/tools/linux-desktop/portal_probe.py
if [[ -f "$probe" ]]; then
  python3 "$probe" --app-id "$APP_ID" > "$EVIDENCE_DIR/probe.json"
else
  # portal_probe.py (T2) is not in this tree yet. Record raw portal introspection instead.
  python3 - > "$EVIDENCE_DIR/probe.json" <<'PY'
import json, re, subprocess

def gdbus(*args):
    return subprocess.run(['gdbus', *args], capture_output=True, text=True, timeout=10).stdout

dest = ['--session', '--dest', 'org.freedesktop.portal.Desktop', '--object-path', '/org/freedesktop/portal/desktop']
names = re.findall(r'interface (org\.freedesktop\.portal\.[A-Za-z]+) \{', gdbus('introspect', *dest))
versions = {}
for name in names:
    m = re.search(r'uint32 (\d+)', gdbus('call', *dest, '--method', 'org.freedesktop.DBus.Properties.Get', name, 'version'))
    versions[name] = int(m.group(1)) if m else None
print(json.dumps({'probe': 'introspection-only', 'interfaces': versions}, indent=2, sort_keys=True))
PY
fi

cat "$EVIDENCE_DIR/permission-store.txt" "$EVIDENCE_DIR/versions.json" "$EVIDENCE_DIR/probe.json"
