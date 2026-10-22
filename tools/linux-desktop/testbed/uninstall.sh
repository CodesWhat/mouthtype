#!/bin/bash
# Remove what install.sh added, following the "Removing" section of agent-install.md, and also take out the
# shell.json entry and the shortcut block the plugin wrote. Speech models stay unless --purge-models is given.
set -uo pipefail
. /opt/testbed/env.sh
PURGE=0; [[ ${1:-} == --purge-models ]] && PURGE=1
PLUGIN=$HOME/.config/omarchy/plugins/dstahl.mouthtype

[[ -x $PLUGIN/control.py ]] && "$PLUGIN/control.py" set-shortcut off >/dev/null 2>&1
mouthtype-linux shutdown >/dev/null 2>&1
systemctl --user disable --now mouthtype-linux.service 2>/dev/null
rm -rf "$PLUGIN" "$HOME/.local/lib/mouthtype-linux" "$HOME/.local/bin/mouthtype-linux"
rm -f "$HOME/.config/systemd/user/mouthtype-linux.service" "$HOME/.config/mouthtype/omarchy-plugin.json"
systemctl --user daemon-reload

python3 - <<'PY'
import json, pathlib
path = pathlib.Path.home() / ".config/omarchy/shell.json"
data = json.loads(path.read_text())
for side in data["bar"]["layout"].values():
    side[:] = [entry for entry in side if entry.get("id") != "dstahl.mouthtype"]
path.write_text(json.dumps(data, indent=2) + "\n")
PY

python3 - <<'PY'
import pathlib
path = pathlib.Path.home() / ".config/hypr/bindings.lua"
begin, end = "-- Mouthtype Omarchy plugin shortcut: begin", "-- Mouthtype Omarchy plugin shortcut: end"
text = path.read_text()
if begin in text and end in text:
    head, rest = text.split(begin, 1)
    path.write_text(head.rstrip() + "\n" + rest.split(end, 1)[1])
PY

rm -f "$HOME/.local/share/mouthtype/speech-candidate"
(( PURGE )) && rm -rf /var/lib/testbed/speech-candidate "$HOME/.local/share/mouthtype" "$HOME/.local/state/mouthtype"
hyprctl reload >/dev/null 2>&1
omarchy-restart-shell >/dev/null 2>&1
echo "uninstall ok"
