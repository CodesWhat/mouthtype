#!/bin/bash
# Entry point for the Omarchy-like test desktop on the Mainframe NAS. Run from anywhere in the checkout:
#   bash tools/linux-desktop/testbed/testbed.sh up | status | password | install | uninstall | smoke | screenshot FILE | shell | logs | down
# Everything goes through ~/scripts/nas-docker.sh. It never touches the NAS host daemon.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
NAS=(bash "$HOME/scripts/nas-docker.sh")
PROJECT=mouthtype-omarchy-testbed
HOST=${TESTBED_HOST:-100.79.136.28}
export TESTBED_PORT=${TESTBED_PORT:-20010}
PASSWORD_COPY=${TESTBED_PASSWORD_FILE:-$HOME/.config/mouthtype-testbed/vnc-password}

compose() {
  local files=(-f "$HERE/compose.yaml")
  [[ ${TESTBED_RENDER:-auto} != software && -n ${RENDER_GID:-} ]] && files+=(-f "$HERE/compose.gpu.yaml")
  NAS_WORKSPACE=${NAS_WORKSPACE:-$("${NAS[@]}" --path "$ROOT")} "${NAS[@]}" compose -p "$PROJECT" "${files[@]}" "$@"
}
inside() { "${NAS[@]}" exec "$PROJECT-desktop-1" "$@"; }
as_user() { inside bash -lc ". /opt/testbed/env.sh; $*"; }

detect_gpu() {
  # The inner engine passes /dev/dri through only when the NAS kernel has it; probe with a throwaway container.
  [[ ${TESTBED_RENDER:-auto} == software ]] && return 0
  local gid
  gid=$("${NAS[@]}" run --rm --device /dev/dri alpine stat -c %g /dev/dri/renderD128 2>/dev/null || true)
  if [[ $gid =~ ^[0-9]+$ ]]; then export RENDER_GID=$gid; else echo "No /dev/dri on the NAS engine; using software rendering." >&2; export TESTBED_RENDER=software; fi
}

case "${1:-}" in
  up)
    shift
    detect_gpu
    export NAS_WORKSPACE
    NAS_WORKSPACE=$("${NAS[@]}" --sync "$ROOT")
    compose up -d --build "$@"
    for _ in $(seq 120); do as_user 'test -e $STATE/ready' 2>/dev/null && break; sleep 2; done
    as_user 'test -e $STATE/ready' || { echo "Session did not come up; see: testbed.sh logs" >&2; exit 1; }
    as_user 'for _ in $(seq 120); do omarchy-shell shell ping >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1' || echo "warning: Omarchy shell did not answer within 2 minutes" >&2
    echo "render mode: $(as_user 'cat $STATE/render-mode')"
    echo "VNC: vnc://$HOST:$TESTBED_PORT   (password: testbed.sh password)"
    ;;
  resync)
    "${NAS[@]}" --sync "$ROOT" >/dev/null && echo "checkout restaged"
    ;;
  status)
    compose ps
    as_user 'cat $STATE/render-mode; hyprctl monitors -j | jq -r ".[] | .name + \" \" + (.width|tostring) + \"x\" + (.height|tostring)"; pgrep -a "Hyprland|quickshell|wayvnc|pipewire|wireplumber" | cut -c1-90'
    ;;
  password)
    # Stores a copy on this Mac (0600) and prints it only when asked with --show.
    mkdir -p "$(dirname "$PASSWORD_COPY")"
    ( umask 077; inside cat /home/omarchy/.config/testbed/vnc-password > "$PASSWORD_COPY" )
    echo "saved to $PASSWORD_COPY"
    case "${2:-}" in
      --copy) pbcopy < "$PASSWORD_COPY"; echo "copied to the clipboard" ;;
      --show) cat "$PASSWORD_COPY"; echo ;;
    esac
    ;;
  install)   as_user /opt/testbed/install.sh ;;
  uninstall) shift; as_user /opt/testbed/uninstall.sh "$@" ;;
  smoke)
    shift
    rm -f "$HERE/.last-smoke.png"
    status=0
    as_user "/opt/testbed/smoke.sh $*" || status=$?
    "${NAS[@]}" cp "$PROJECT-desktop-1:/tmp/smoke.png" "$HERE/.last-smoke.png" 2>/dev/null && echo "screenshot: $HERE/.last-smoke.png" || true
    exit "$status"
    ;;
  screenshot)
    as_user 'grim -o $TESTBED_OUTPUT /tmp/shot.png'
    "${NAS[@]}" cp "$PROJECT-desktop-1:/tmp/shot.png" "${2:-./omarchy-testbed.png}"
    ;;
  shell) shift; "${NAS[@]}" exec -it "$PROJECT-desktop-1" bash -lc ". /opt/testbed/env.sh; exec bash" ;;
  logs)  as_user 'tail -n 60 $STATE/*.log' ;;
  down)
    # Containers and network go. The model volume stays unless --purge is given.
    if [[ ${2:-} == --purge ]]; then compose down -v; else compose down; fi
    ;;
  *)
    sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
