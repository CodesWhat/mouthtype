#!/usr/bin/env bash
# Bring up a headless GNOME 50 Wayland session and record what is installed.
# Usage: run.sh [output-dir]   (default ~/evidence). Inside the session this
# script re-executes itself as "inner" to collect versions once the shell is up.
set -euo pipefail

out=${1:-$HOME/evidence}

if [[ "${1:-}" != --inner ]]; then
  mkdir -p "$out"
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp/xdg-runtime-$(id -u)}
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
  export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME
  exec dbus-run-session -- "$0" --inner "$out"
fi

out=$2
shell_log="$out/gnome-shell.log"
gnome-shell --headless --wayland --no-x11 --virtual-monitor 1280x800 > "$shell_log" 2>&1 &
shell_pid=$!
trap 'kill "$shell_pid" 2>/dev/null || true' EXIT

# Ready when the shell owns its bus name.
ready=0
for _ in $(seq 1 60); do
  if ! kill -0 "$shell_pid" 2>/dev/null; then break; fi
  if gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
       --method org.freedesktop.DBus.NameHasOwner org.gnome.Shell 2>/dev/null | grep -q true; then
    ready=1
    break
  fi
  sleep 1
done

if [[ $ready == 1 ]]; then
  dbus-update-activation-environment --systemd WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=GNOME 2>/dev/null \
    || dbus-update-activation-environment WAYLAND_DISPLAY=wayland-0 XDG_CURRENT_DESKTOP=GNOME
  sleep 3
fi

python3 - "$out/versions.json" "$ready" "$shell_pid" <<'PY'
import json, subprocess, sys

dest, ready, pid = sys.argv[1], sys.argv[2] == '1', int(sys.argv[3])

def run(*cmd):
    done = subprocess.run(cmd, capture_output=True, text=True)
    return done.stdout.strip() if done.returncode == 0 else ''

packages = {}
for name in ('gnome-shell', 'mutter-common', 'gnome-control-center', 'xdg-desktop-portal',
             'xdg-desktop-portal-gnome', 'pipewire', 'wireplumber', 'at-spi2-core',
             'python3-jeepney', 'python3-gi', 'gir1.2-atspi-2.0', 'gir1.2-gtk-3.0',
             'gnome-shell-extension-appindicator'):
    packages[name] = run('dpkg-query', '-W', '-f=${Version}', name) or None

candidate = open('/opt/appindicator-policy.txt').read().strip()
extensions = run('gnome-extensions', 'list', '--enabled').splitlines()
with open('/etc/os-release') as handle:
    release = dict(line.rstrip().split('=', 1) for line in handle if '=' in line)
alive = True
try:
    import os
    os.kill(pid, 0)
except OSError:
    alive = False
json.dump({
    'os': release.get('PRETTY_NAME', '').strip('"'),
    'shell_running': ready and alive,
    'packages': packages,
    'enabled_extensions': extensions,
    'appindicator_apt_policy': candidate,
    'appindicator_enabled': any('appindicator' in item.lower() for item in extensions),
}, open(dest, 'w'), indent=2)
PY

cat "$out/versions.json"
[[ $ready == 1 ]] || { echo 'gnome-shell did not come up; see gnome-shell.log' >&2; tail -n 40 "$shell_log" >&2; exit 1; }
