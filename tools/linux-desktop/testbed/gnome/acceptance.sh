#!/usr/bin/env bash
# Bring up the headless GNOME session and run the gnome-portal acceptance component inside it.
# Usage: acceptance.sh [output-dir]   (default ~/evidence). Writes gnome-portal.json next to gnome-shell.log.
set -euo pipefail

out=${1:-$HOME/evidence}
acceptance=${MOUTHTYPE_ACCEPTANCE:-/opt/mouthtype/tools/linux-desktop/acceptance.py}

if [[ "${1:-}" != --inner ]]; then
  mkdir -p "$out"
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-$(id -u)}
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
  export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME
  exec dbus-run-session -- "$0" --inner "$out"
fi

out=$2
gnome-shell --headless --unsafe-mode --wayland --no-x11 --virtual-monitor 1280x800 > "$out/gnome-shell.log" 2>&1 &
shell_pid=$!
trap 'kill "$shell_pid" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 60); do
  kill -0 "$shell_pid" 2>/dev/null || break
  if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
       --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell 2>/dev/null | grep -q true; then
    ready=1
    break
  fi
  sleep 1
done
[[ $ready == 1 ]] || { echo 'gnome-shell did not come up; see gnome-shell.log' >&2; tail -n 40 "$out/gnome-shell.log" >&2; exit 1; }

dbus-update-activation-environment --systemd WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=GNOME 2>/dev/null \
  || dbus-update-activation-environment WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=GNOME
sleep 3

status=0
MOUTHTYPE_ACCEPTANCE_EVIDENCE="$out" python3 "$acceptance" gnome-portal > "$out/gnome-portal.json" || status=$?
cat "$out/gnome-portal.json"
exit "$status"
