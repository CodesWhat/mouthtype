# Source this to talk to the running session from `docker exec`.
STATE="$HOME/.local/state/testbed"
set -a
[[ -r $STATE/session.env ]] && . "$STATE/session.env"
set +a
export PATH="$OMARCHY_PATH/bin:$HOME/.local/bin:$PATH"
