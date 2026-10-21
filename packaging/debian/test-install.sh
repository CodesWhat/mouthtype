#!/usr/bin/env bash
# Install, check, remove and purge a built .deb in a clean Debian or Ubuntu container (run as root).
#
#   bash packaging/debian/test-install.sh /path/to/mouthtype-linux_*.deb
#
# Used by the CI job and by the container matrix in packaging/debian/README.md. It needs network access to the
# distribution mirrors and changes the container it runs in, so do not run it on a machine you care about.
set -euo pipefail

deb=$(realpath "${1:?usage: test-install.sh PATH-TO.deb}")
[ "$(id -u)" = 0 ] || { echo "run as root inside a disposable container" >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

leftovers() {
    find /usr /etc /var/lib/dpkg/info -name '*mouthtype*' 2>/dev/null || true
}

step "os"
. /etc/os-release
echo "$PRETTY_NAME"

step "apt install"
apt-get update -qq
apt-get install -y "$deb"
dpkg -s mouthtype-linux | sed -n '1,/^Description/p'

step "files"
for path in /usr/bin/mouthtype-linux /usr/bin/mouthtype-linux-setup \
            /usr/lib/mouthtype-linux/tools/linux-desktop/desktop.py \
            /usr/lib/systemd/user/mouthtype-linux.service \
            /usr/share/mouthtype-linux/omarchy-plugin/manifest.json \
            /usr/share/doc/mouthtype-linux/copyright; do
    [ -e "$path" ] || fail "missing $path"
done
outside=$(dpkg -L mouthtype-linux | grep -vE '^(/usr(/|$)|/\.$)' || true)
[ -z "$outside" ] || { echo "$outside"; fail "package owns files outside /usr"; }
test ! -e /etc/systemd/user/default.target.wants/mouthtype-linux.service || fail "package enabled the service"

step "binary"
mouthtype-linux --help >/dev/null
mouthtype-linux capabilities | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["interface"] == 1, d'
mouthtype-linux-setup --help >/dev/null

step "payload unit tests"
python3 -W error::ResourceWarning -m unittest discover -s /usr/lib/mouthtype-linux/tools/linux-desktop -p 'test_spellings.py' 2>&1 | tail -3

step "doctor (ordinary user, no config)"
id mt-test >/dev/null 2>&1 || useradd --create-home --shell /bin/bash mt-test
doctor=$(runuser -u mt-test -- mouthtype-linux doctor || true)
echo "$doctor" | python3 -c '
import json, sys
data = json.load(sys.stdin)
checks = {c["name"]: c["status"] for c in data["checks"]}
print(checks)
for name in ("platform", "capture", "python"):
    assert checks.get(name) == "ok", (name, checks)
'
systemd-analyze --user verify /usr/lib/systemd/user/mouthtype-linux.service 2>/dev/null || true

step "apt remove"
apt-get remove -y mouthtype-linux >/dev/null
test ! -e /usr/bin/mouthtype-linux || fail "launcher left after remove"
test ! -e /usr/lib/mouthtype-linux || fail "payload left after remove"
test ! -e /usr/share/mouthtype-linux || fail "plugin left after remove"
test ! -e /usr/lib/systemd/user/mouthtype-linux.service || fail "unit left after remove"

step "apt install again, then purge"
apt-get install -y "$deb" >/dev/null
apt-get purge -y mouthtype-linux >/dev/null
left=$(leftovers)
[ -z "$left" ] || { echo "$left"; fail "files left after purge"; }
dpkg -s mouthtype-linux >/dev/null 2>&1 && fail "still known to dpkg" || true
[ -e /home/mt-test ] && echo "home directory untouched: ok"

echo; echo "PASS $PRETTY_NAME"
