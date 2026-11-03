#!/bin/bash
# Container entrypoint: make the VNC password, then run the whole desktop session under one session bus.
set -euo pipefail

STATE="$HOME/.local/state/testbed"
mkdir -p "$STATE" "$XDG_RUNTIME_DIR" "$HOME/.config/testbed"
chmod 700 "$XDG_RUNTIME_DIR"

# The password comes from the environment when the caller sets one, and is generated otherwise. It is
# written to a 0600 file inside the container and never printed or logged. RFB caps it at 8 characters.
PASSWORD_FILE="$HOME/.config/testbed/vnc-password"
if [[ -n ${TESTBED_VNC_PASSWORD:-} ]]; then
  (( ${#TESTBED_VNC_PASSWORD} <= 8 )) || { echo "TESTBED_VNC_PASSWORD must be 8 characters or fewer (RFB limit)." >&2; exit 2; }
  ( umask 077; printf '%s' "$TESTBED_VNC_PASSWORD" > "$PASSWORD_FILE" )
elif [[ ! -s $PASSWORD_FILE ]]; then
  ( umask 077; head -c 64 /dev/urandom | tr -dc 'A-HJ-NP-Za-km-z2-9' | head -c 8 > "$PASSWORD_FILE" )
fi
unset TESTBED_VNC_PASSWORD
export TESTBED_VNC_PASSWORD_FILE="$PASSWORD_FILE"

# A volume mounted over the speech directory may be root-owned on first use.
[[ -w /var/lib/testbed ]] || sudo chown omarchy:omarchy /var/lib/testbed

exec dbus-run-session -- /opt/testbed/session.sh
