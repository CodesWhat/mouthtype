#!/bin/bash
# End-to-end smoke test, run inside the container (testbed.sh smoke does this). It checks the session,
# installs the client from /src if needed, dictates a known sentence through the virtual microphone with the
# real shortcut, checks the text lands in a focused Wayland text field, and takes a grim screenshot.
# Flags: --fresh uninstall and reinstall first, --no-install expect an existing install. Exit 0 only if every check passed.
set -uo pipefail
. /opt/testbed/env.sh

EXPECTED="the quick brown fox jumps over the lazy dog"
CLASS=app.mouthtype.Acceptance
PLUGIN=$HOME/.config/omarchy/plugins/dstahl.mouthtype
TARGET_JSON=/tmp/smoke-target.json
SHOT=/tmp/smoke.png
FRESH=0; INSTALL=1
for arg in "$@"; do case $arg in --fresh) FRESH=1 ;; --no-install) INSTALL=0 ;; esac; done

failed=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failed=$((failed + 1)); }
check() { local name=$1; shift; if "$@" >/tmp/smoke-step.log 2>&1; then pass "$name"; else fail "$name"; sed 's/^/      /' /tmp/smoke-step.log | tail -8; return 1; fi; }
state() { mouthtype-linux status 2>/dev/null | jq -r '.state // empty'; }
wait_state() { local want=$1 limit=$2; for _ in $(seq $((limit * 4))); do [[ $(state) == "$want" ]] && return 0; sleep 0.25; done; return 1; }
normalize() { tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }
target_text() { jq -r '.text // ""' "$TARGET_JSON" 2>/dev/null; }

echo "== session"
check "Hyprland answers hyprctl" hyprctl version
check "Hyprland output is 1920x1080" bash -c "hyprctl monitors -j | jq -e 'any(.[]; .width==1920 and .height==1080)'"
check "Omarchy shell is up" bash -c 'for _ in $(seq 60); do omarchy-shell shell ping >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
check "wayvnc and the password gate are listening" bash -c 'ss -ltn | grep -q ":5900 " && ss -ltn | grep -q "127.0.0.1:5901"'
check "virtual microphone node exists" bash -c 'for _ in $(seq 20); do pw-dump | jq -e "any(.[]; .info.props[\"node.name\"]==\"mouthtype_virtual_mic\")" && exit 0; sleep 0.5; done; exit 1'
echo "render mode: $(cat "$STATE/render-mode")"

echo "== install"
if (( FRESH )) && [[ -e $HOME/.local/lib/mouthtype-linux ]]; then check "uninstall (fresh run)" /opt/testbed/uninstall.sh; fi
if [[ -e $HOME/.local/lib/mouthtype-linux ]]; then
  pass "client already installed (use --fresh to reinstall)"
elif (( INSTALL )); then
  /opt/testbed/install.sh && pass "install from /src" || fail "install from /src"
fi
check "mouthtype-linux status is idle" bash -c '[[ $(mouthtype-linux status | jq -r .state) == idle ]]'
check "plugin is in the Omarchy bar config" jq -e '.bar.layout.right | any(.[]; .id=="dstahl.mouthtype")' "$HOME/.config/omarchy/shell.json"

echo "== shortcut"
check "toggle shortcut F10 bound" bash -c "\"$PLUGIN/control.py\" set-shortcut toggle F10 >/dev/null; hyprctl -j binds | jq -e 'any(.[]; .key==\"F10\")'"
check "delivery is paste" bash -c "\"$PLUGIN/control.py\" set-config delivery paste >/dev/null; jq -e '.delivery.mode==\"paste\"' $HOME/.local/share/mouthtype/speech-candidate/linux.json"

echo "== text field"
rm -f "$TARGET_JSON"
GDK_BACKEND=wayland PYTHONDONTWRITEBYTECODE=1 setsid python3 "${SRC:-/src}/tools/linux-desktop/wayland_target.py" "$TARGET_JSON" >/tmp/smoke-target.log 2>&1 &
TARGET_PID=$!
trap 'kill $TARGET_PID 2>/dev/null' EXIT
check "text field window mapped" bash -c "for _ in \$(seq 40); do hyprctl clients -j | jq -e 'any(.[]; .class==\"$CLASS\")' && exit 0; sleep 0.5; done; exit 1"
hyprctl dispatch "hl.dsp.focus({ window = \"class:$CLASS\" })" >/dev/null
check "text field has focus" bash -c "sleep 0.5; hyprctl activewindow -j | jq -e '.class==\"$CLASS\"'"

echo "== dictation"
# The shortcut is triggered by running the exact command the F10 bind runs, through hyprctl dispatch. A wtype
# key press does reach Hyprland's binds, but on a headless session only some presses register (README, Known
# limits), which would make this check flaky for reasons unrelated to Mouthtype.
toggle() {
  hyprctl dispatch "hl.dsp.exec_cmd(\"$PLUGIN/control.py toggle\")" >/dev/null
}
toggle start
check "recording started" wait_state recording 5
sleep 0.5
pw-play --target mouthtype_mic_input /opt/testbed/sample.wav
sleep 1.0
toggle stop
# The first take loads the speech model, which can take a while on this CPU.
check "take finished and returned to idle" wait_state idle 180
for _ in $(seq 60); do [[ -n $(target_text) ]] && break; sleep 0.5; done
got=$(target_text | normalize)
echo "      text in the field: \"$(target_text)\""
if [[ $got == "$EXPECTED" ]]; then pass "text in the field matches the sample"; else fail "text in the field differs: wanted \"$EXPECTED\", got \"$got\""; fi

echo "== screenshot"
check "grim screenshot" grim -o "$TESTBED_OUTPUT" "$SHOT"
check "screenshot is not blank" bash -c "[[ \$(magick '$SHOT' -format '%[fx:minima!=maxima ? 1 : 0]' info:) == 1 ]]"

echo
if (( failed )); then echo "SMOKE FAILED: $failed check(s)"; exit 1; fi
echo "SMOKE PASSED"
