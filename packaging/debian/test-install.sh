#!/usr/bin/env bash
# Install, check, remove and purge a built .deb in a clean Debian or Ubuntu container (run as root).
#
#   bash packaging/debian/test-install.sh /path/to/mouthtype-linux_*.deb [/path/to/mouthtype-linux-desktop_*.deb]
#
# With the second .deb it installs both and also checks the desktop package, which needs xdg-desktop-portal 1.19 or
# newer (Debian 13, Ubuntu 26.04). On older releases pass only the core .deb.
#
# Used by the CI job and by the container matrix in packaging/debian/README.md. It needs network access to the
# distribution mirrors and changes the container it runs in, so do not run it on a machine you care about.
set -euo pipefail

deb=$(realpath "${1:?usage: test-install.sh PATH-TO.deb [PATH-TO-DESKTOP.deb]}")
desktop_deb=${2:+$(realpath "$2")}
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
apt-get install -y "$deb" ${desktop_deb:+"$desktop_deb"}
dpkg -s mouthtype-linux | sed -n '1,/^Description/p'

step "files"
for path in /usr/bin/mouthtype-linux /usr/bin/mouthtype-linux-setup \
            /usr/lib/mouthtype-linux/tools/linux-desktop/desktop.py \
            /usr/lib/systemd/user/mouthtype-linux.service \
            /usr/lib/systemd/user/graphical-session.target.wants/mouthtype-linux-firstrun.service \
            /usr/lib/mouthtype-linux/tools/linux-desktop/firstrun.py \
            /usr/lib/mouthtype-linux/tools/linux-desktop/cli_firstrun.py \
            /usr/share/mouthtype-linux/omarchy-plugin/manifest.json \
            /usr/share/doc/mouthtype-linux/copyright; do
    [ -e "$path" ] || fail "missing $path"
done
outside=$(dpkg -L mouthtype-linux | grep -vE '^(/usr(/|$)|/\.$)' || true)
[ -z "$outside" ] || { echo "$outside"; fail "package owns files outside /usr"; }
test ! -e /etc/systemd/user/default.target.wants/mouthtype-linux.service || fail "package enabled the service"

step "core package pulls no Qt"
if [ -z "$desktop_deb" ]; then
    ! dpkg -s python3-pyside6.qtcore >/dev/null 2>&1 || fail "core package installed PySide6"
fi

if [ -n "$desktop_deb" ]; then
    step "desktop package"
    dpkg -s mouthtype-linux-desktop | sed -n '1,/^Description/p'
    for path in /usr/bin/mouthtype-desktop \
                /usr/lib/mouthtype-linux/tools/linux-qt/mouthtype_desktop.py \
                /usr/lib/mouthtype-linux/tools/linux-qt/Main.qml \
                /usr/lib/mouthtype-linux/tools/linux-qt/tray.py \
                /usr/lib/mouthtype-linux/tools/linux-qt/platform/qt/MouthtypePlatform/qmldir \
                /usr/lib/mouthtype-linux/tools/omarchy-plugin/MouthtypeShell.qml \
                /usr/share/applications/app.mouthtype.Mouthtype.Settings.desktop \
                /usr/share/icons/hicolor/symbolic/apps/app.mouthtype.Mouthtype-symbolic.svg \
                /usr/share/doc/mouthtype-linux-desktop/copyright; do
        [ -e "$path" ] || fail "missing $path"
    done
    outside=$(dpkg -L mouthtype-linux-desktop | grep -vE '^(/usr(/|$)|/\.$)' || true)
    [ -z "$outside" ] || { echo "$outside"; fail "desktop package owns files outside /usr"; }
    [ "$(dpkg-query -W -f='${Architecture}' mouthtype-linux-desktop)" = all ] || fail "desktop package is not Architecture: all"
    mouthtype-desktop --help >/dev/null
    # Offscreen launch with the packaged QML and the packaged control helper: the settings window must load.
    id mt-desktop >/dev/null 2>&1 || useradd --create-home --shell /bin/bash mt-desktop
    runuser -u mt-desktop -- env QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
        timeout --kill-after=5s 60s mouthtype-desktop --page home --screenshot /tmp/mouthtype-desktop-home.png
    [ -s /tmp/mouthtype-desktop-home.png ] || fail "offscreen settings window did not render"
fi

step "binary"
mouthtype-linux --help >/dev/null
mouthtype-linux capabilities | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["interface"] == 1, d'
mouthtype-linux-setup --help >/dev/null

step "payload unit tests"
python3 -W error::ResourceWarning -m unittest discover -s /usr/lib/mouthtype-linux/tools/linux-desktop -p 'test_spellings.py' 2>&1 | tail -3

step "doctor (ordinary user, no config)"
id mt-test >/dev/null 2>&1 || useradd --create-home --shell /bin/bash mt-test
doctor=$(runuser -u mt-test -- mouthtype-linux doctor 2>&1 || true)
echo "$doctor" | head -40
for name in platform capture python; do
    echo "$doctor" | grep -q "^OK $name:" || fail "doctor check $name is not OK"
done
systemd-analyze --user verify /usr/lib/systemd/user/mouthtype-linux.service 2>/dev/null || true

step "apt remove"
apt-get remove -y mouthtype-linux ${desktop_deb:+mouthtype-linux-desktop} >/dev/null
test ! -e /usr/bin/mouthtype-linux || fail "launcher left after remove"
test ! -e /usr/lib/mouthtype-linux || fail "payload left after remove"
test ! -L /usr/lib/systemd/user/graphical-session.target.wants/mouthtype-linux-firstrun.service || fail "first-run link left after remove"
test ! -e /usr/share/mouthtype-linux || fail "plugin left after remove"
test ! -e /usr/bin/mouthtype-desktop || fail "desktop launcher left after remove"
test ! -e /usr/share/applications/app.mouthtype.Mouthtype.Settings.desktop || fail "desktop entry left after remove"
test ! -e /usr/lib/systemd/user/mouthtype-linux.service || fail "unit left after remove"

step "apt install again, then purge"
apt-get install -y "$deb" ${desktop_deb:+"$desktop_deb"} >/dev/null
apt-get purge -y mouthtype-linux ${desktop_deb:+mouthtype-linux-desktop} >/dev/null
left=$(leftovers)
[ -z "$left" ] || { echo "$left"; fail "files left after purge"; }
dpkg -s mouthtype-linux >/dev/null 2>&1 && fail "still known to dpkg" || true
[ -e /home/mt-test ] && echo "home directory untouched: ok"

echo; echo "PASS $PRETTY_NAME"
