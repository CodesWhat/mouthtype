#!/bin/bash
# The desktop session: audio, Hyprland (headless) with Omarchy's config, wayvnc behind the password gate.
set -uo pipefail

STATE="$HOME/.local/state/testbed"
rm -f "$STATE/ready"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$STATE/session.log"; }

# Rendering. gpu uses the DRI render node; software forces Mesa's llvmpipe. auto picks gpu when a node exists.
RENDER=${TESTBED_RENDER:-auto}
if [[ $RENDER == auto ]]; then
  if compgen -G '/dev/dri/renderD*' >/dev/null && [[ -r $(compgen -G '/dev/dri/renderD*' | head -1) ]]; then RENDER=gpu; else RENDER=software; fi
fi
if [[ $RENDER == software ]]; then
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe MESA_LOADER_DRIVER_OVERRIDE=swrast
fi
echo "$RENDER" > "$STATE/render-mode"
log "render mode: $RENDER"

# Audio: PipeWire, WirePlumber and the Pulse shim, then the virtual microphone from conf.d.
pipewire >"$STATE/pipewire.log" 2>&1 &
for _ in $(seq 50); do [[ -S $XDG_RUNTIME_DIR/pipewire-0 ]] && break; sleep 0.1; done
wireplumber >"$STATE/wireplumber.log" 2>&1 &
pipewire-pulse >"$STATE/pipewire-pulse.log" 2>&1 &

# Compositor. Hyprland 0.56 only starts on a DRM seat or as a window of another Wayland compositor (it needs
# xdg_wm_base and wl_compositor version 6, which wlroots-based hosts like sway don't offer yet). The NAS has no
# display, so a headless mutter exists purely to give Aquamarine a host and allocator to start against.
mutter --headless --wayland --no-x11 --virtual-monitor 1920x1080 --wayland-display testbed-outer >"$STATE/mutter.log" 2>&1 &
OUTER=testbed-outer
for _ in $(seq 100); do [[ -S $XDG_RUNTIME_DIR/$OUTER ]] && break; sleep 0.2; done
[[ -S $XDG_RUNTIME_DIR/$OUTER ]] || { log "mutter did not start"; tail -20 "$STATE/mutter.log"; exit 1; }
export XDG_SESSION_DESKTOP=Hyprland HYPRLAND_NO_SD_NOTIFY=1
WAYLAND_DISPLAY=$OUTER Hyprland >"$STATE/hyprland.log" 2>&1 &
HYPR=$!

for _ in $(seq 150); do
  kill -0 "$HYPR" 2>/dev/null || { log "Hyprland exited at startup"; tail -20 "$STATE/hyprland.log"; exit 1; }
  sig=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1 || true)
  [[ -n $sig && -S $XDG_RUNTIME_DIR/hypr/$sig/.socket.sock ]] && break
  sleep 0.2
done
export HYPRLAND_INSTANCE_SIGNATURE=$sig
# The nested window never maps (mutter's software path can't take Hyprland's GPU buffers), so the real
# output is a Hyprland headless one, rendered by Hyprland itself on the DRI node.
hyprctl output create headless >/dev/null 2>&1
for _ in $(seq 50); do hyprctl monitors -j 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1 && break; sleep 0.2; done
display=$(ls -t "$XDG_RUNTIME_DIR" | grep -E '^wayland-[0-9]+$' | head -1 || true)
export WAYLAND_DISPLAY=${display:?Hyprland created no Wayland socket}
OUTPUT=$(hyprctl monitors -j | jq -r '.[0].name')
{ echo "HYPRLAND_INSTANCE_SIGNATURE=$sig"; echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"; echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"; echo "TESTBED_OUTPUT=$OUTPUT"; } > "$STATE/session.env"
log "Hyprland up: $sig on $WAYLAND_DISPLAY hosted by $OUTER, output $OUTPUT"
log "outputs: $(hyprctl monitors -j | jq -r 'map(.name + " " + (.width|tostring) + "x" + (.height|tostring)) | join(", ")')"

# A headless Hyprland has no keyboard, and Hyprland's send_shortcut (the paste path) refuses to run without
# one. A resident wtype virtual keyboard supplies it. wtype builds the keymap from what it is asked to type,
# so the alphabet, digits, function keys and modifiers are typed once now, while no window can take them.
keyboard() {
  local keys=() i
  for i in $(seq 1 12); do keys+=(-k "F$i"); done
  while true; do
    wtype 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ' "${keys[@]}" \
      -k Control_L -k Shift_L -k Alt_L -k Super_L -k Return -k Escape -s 2000000000 >/dev/null 2>&1
    sleep 1
  done
}
keyboard &

# wayvnc stays on loopback with no auth; the proxy owns the public port and the password.
wayvnc -o "$OUTPUT" 127.0.0.1 5901 >"$STATE/wayvnc.log" 2>&1 &
python3 /opt/testbed/vnc-auth-proxy.py >"$STATE/vnc-proxy.log" 2>&1 &
log "VNC listening on 5900 (password in ~/.config/testbed/vnc-password)"

# Units enabled by an earlier install start with the graphical session, as systemd would.
for unit in "$HOME/.config/systemd/user/graphical-session.target.wants/"*.service; do
  [[ -e $unit ]] && systemctl --user start "$(basename "$unit")"
done

touch "$STATE/ready"
wait "$HYPR"
log "Hyprland exited"
