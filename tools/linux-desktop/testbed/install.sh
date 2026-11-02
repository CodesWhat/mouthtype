#!/bin/bash
# Install the Mouthtype Linux client and its Omarchy plugin from the checkout mounted at /src, using the
# repository's own installers, in the order website/public/linux/agent-install.md gives. Stops on a failed check.
set -euo pipefail
. /opt/testbed/env.sh
SRC=${SRC:-/src}
SPEECH=/var/lib/testbed/speech-candidate
LINK=$HOME/.local/share/mouthtype/speech-candidate

step() { printf '\n== %s\n' "$*"; }
[[ -f $SRC/tools/linux-desktop/install.py ]] || { echo "No Mouthtype checkout at $SRC (tools/linux-desktop/install.py missing)." >&2; exit 2; }
[[ -e $HOME/.local/lib/mouthtype-linux ]] && { echo "Already installed. Run uninstall first." >&2; exit 3; }
export PYTHONDONTWRITEBYTECODE=1

step "1. prerequisites"
for tool in pw-record ffprobe wl-copy wtype hyprctl python3 curl; do command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }; done
hyprctl version | head -1
echo "$PATH" | tr : '\n' | grep -qx "$HOME/.local/bin"

step "2. client (tools/linux-desktop/install.py)"
python3 "$SRC/tools/linux-desktop/install.py" --prefix "$HOME/.local"
mouthtype-linux capabilities | jq -e '.interface == 1 and (.features.file_transcription // .file_transcription) != null' >/dev/null \
  || mouthtype-linux capabilities | head -c 400

step "3. speech model (cached in the testbed volume after the first run)"
if [[ ! -f $SPEECH/linux.json ]]; then
  rm -rf "$SPEECH"
  python3 "$SRC/tools/linux-desktop/setup_speech.py" --destination "$SPEECH"
else
  echo "reusing $SPEECH"
fi
mkdir -p "$(dirname "$LINK")"
ln -sfn "$SPEECH" "$LINK"
mouthtype-linux --config "$LINK/linux.json" doctor || true

step "4. Omarchy plugin (tools/omarchy-plugin/install.py)"
python3 "$SRC/tools/omarchy-plugin/install.py"

step "5. paste delivery"
"$HOME/.config/omarchy/plugins/dstahl.mouthtype/control.py" set-config delivery paste >/dev/null

step "6. service"
for _ in $(seq 40); do
  state=$(mouthtype-linux status 2>/dev/null | jq -r '.state // empty' || true)
  [[ $state == idle ]] && break
  sleep 0.5
done
mouthtype-linux status
[[ $state == idle ]]
echo "install ok"
