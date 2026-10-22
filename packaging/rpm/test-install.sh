#!/usr/bin/env bash
# Lint, install, check, remove and reinstall built rpms in a clean Fedora container (run as root).
#
#   bash packaging/rpm/test-install.sh /path/to/mouthtype-linux-*.x86_64.rpm [/path/to/mouthtype-linux-desktop-*.noarch.rpm]
#
# With the second rpm it installs both and also checks the desktop package, which needs xdg-desktop-portal 1.19 or
# newer (Fedora 44). Used by the container matrix in packaging/rpm/README.md. It needs network access to the Fedora
# mirrors and changes the container it runs in, so do not run it on a machine you care about.
set -euo pipefail

rpm_core=$(realpath "${1:?usage: test-install.sh PATH-TO.rpm [PATH-TO-DESKTOP.rpm]}")
rpm_desktop=${2:+$(realpath "$2")}
[ "$(id -u)" = 0 ] || { echo "run as root inside a disposable container" >&2; exit 2; }

step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "os"
. /etc/os-release
echo "$PRETTY_NAME"

step "rpmlint"
dnf -y -q install rpmlint
# Errors fail the run. Warnings are printed: the package is not in Fedora's archive, so no-documentation,
# no-manual-page and similar archive-policy findings are not blockers. no-binary is expected: the core package is
# pinned to x86_64 because the speech wheels are, though it ships only Python and QML.
rpmlint_out=$(rpmlint "$rpm_core" ${rpm_desktop:+"$rpm_desktop"} 2>&1 || true)
echo "$rpmlint_out" | tail -40
if echo "$rpmlint_out" | grep -E ': E: ' | grep -vE ' no-binary'; then fail "rpmlint reported errors"; fi

step "dnf install"
dnf -y install "$rpm_core" ${rpm_desktop:+"$rpm_desktop"}
rpm -qi mouthtype-linux | sed -n '1,/^Description/p'

step "files"
for path in /usr/bin/mouthtype-linux /usr/bin/mouthtype-linux-setup \
            /usr/lib/mouthtype-linux/tools/linux-desktop/desktop.py \
            /usr/lib/systemd/user/mouthtype-linux.service \
            /usr/lib/systemd/user/graphical-session.target.wants/mouthtype-linux-firstrun.service \
            /usr/lib/mouthtype-linux/tools/linux-desktop/firstrun.py \
            /usr/share/mouthtype-linux/omarchy-plugin/manifest.json \
            /usr/share/applications/app.mouthtype.Mouthtype.desktop; do
    [ -e "$path" ] || fail "missing $path"
done
outside=$(rpm -ql mouthtype-linux | grep -vE '^/usr(/|$)' || true)
[ -z "$outside" ] || { echo "$outside"; fail "package owns files outside /usr"; }
test ! -e /etc/systemd/user/default.target.wants/mouthtype-linux.service || fail "package enabled the service"

step "core package pulls no Qt"
if [ -z "$rpm_desktop" ]; then
    ! rpm -q python3-pyside6 >/dev/null 2>&1 || fail "core package installed PySide6"
fi

if [ -n "$rpm_desktop" ]; then
    step "desktop package"
    rpm -qi mouthtype-linux-desktop | sed -n '1,/^Description/p'
    for path in /usr/bin/mouthtype-desktop \
                /usr/lib/mouthtype-linux/tools/linux-qt/mouthtype_desktop.py \
                /usr/lib/mouthtype-linux/tools/linux-qt/Main.qml \
                /usr/lib/mouthtype-linux/tools/linux-qt/tray.py \
                /usr/lib/mouthtype-linux/tools/linux-qt/platform/qt/MouthtypePlatform/qmldir \
                /usr/lib/mouthtype-linux/tools/omarchy-plugin/MouthtypeShell.qml \
                /usr/share/applications/app.mouthtype.Mouthtype.Settings.desktop; do
        [ -e "$path" ] || fail "missing $path"
    done
    outside=$(rpm -ql mouthtype-linux-desktop | grep -vE '^/usr(/|$)' || true)
    [ -z "$outside" ] || { echo "$outside"; fail "desktop package owns files outside /usr"; }
    [ "$(rpm -q --qf '%{ARCH}' mouthtype-linux-desktop)" = noarch ] || fail "desktop package is not noarch"
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

step "doctor --json (ordinary user, no config)"
id mt-test >/dev/null 2>&1 || useradd --create-home --shell /bin/bash mt-test
# Exit 0 is a ready machine, 2 is setup pending (no speech model yet). Anything else is a broken install.
status=0
runuser -u mt-test -- mouthtype-linux doctor --json >/tmp/doctor.json || status=$?
python3 -c 'import json; json.load(open("/tmp/doctor.json"))' || fail "doctor --json did not print JSON"
[ "$status" = 0 ] || [ "$status" = 2 ] || fail "doctor exited $status"
echo "doctor exit $status"

step "dnf remove"
dnf -y remove ${rpm_desktop:+mouthtype-linux-desktop} mouthtype-linux >/dev/null
test ! -e /usr/bin/mouthtype-linux || fail "launcher left after remove"
test ! -e /usr/lib/mouthtype-linux || fail "payload left after remove"
test ! -e /usr/share/mouthtype-linux || fail "plugin left after remove"
test ! -e /usr/bin/mouthtype-desktop || fail "desktop launcher left after remove"
test ! -e /usr/share/applications/app.mouthtype.Mouthtype.Settings.desktop || fail "desktop entry left after remove"
test ! -e /usr/lib/systemd/user/mouthtype-linux.service || fail "unit left after remove"
left=$(find /usr /etc -name '*mouthtype*' 2>/dev/null || true)
[ -z "$left" ] || { echo "$left"; fail "files left after remove"; }

step "dnf install again"
dnf -y install "$rpm_core" ${rpm_desktop:+"$rpm_desktop"} >/dev/null
rpm -q mouthtype-linux >/dev/null
[ -e /home/mt-test ] && echo "home directory untouched: ok"

echo; echo "PASS $PRETTY_NAME"
