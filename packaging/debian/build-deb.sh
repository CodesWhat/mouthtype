#!/usr/bin/env bash
# Build mouthtype-linux_<version>_amd64.deb with plain dpkg-deb. No network, no third-party tools.
#
#   bash packaging/debian/build-deb.sh --output DIR [--version 0.3.0-1]
#
# Without --version the package is a snapshot: <Version.plist>~git<commit-time>.<rev>-1, which sorts below
# the matching stable <Version.plist>-1. Run it on Debian or Ubuntu (needs dpkg-deb, python3, gzip, find).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
here="$root/packaging/debian"
output=
version=
while [ $# -gt 0 ]; do
    case "$1" in
        --output) output=${2:?--output needs a directory}; shift 2 ;;
        --version) version=${2:?--version needs a value}; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$output" ] || { echo "usage: build-deb.sh --output DIR [--version VERSION]" >&2; exit 2; }

base=$(python3 -I -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleShortVersionString'])" "$root/packaging/Version.plist")
if git -C "$root" rev-parse HEAD >/dev/null 2>&1; then
    epoch=$(git -C "$root" show -s --format=%ct HEAD)
    rev=$(git -C "$root" rev-parse --short=12 HEAD)
else
    epoch=${SOURCE_DATE_EPOCH:-$(date +%s)}
    rev=nogit
fi
[ -n "$version" ] || version="${base}~git${epoch}.${rev}-1"
case "$version" in [0-9]*) ;; *) echo "invalid version: $version" >&2; exit 2 ;; esac
export SOURCE_DATE_EPOCH=$epoch

mkdir -p "$output"
output=$(cd "$output" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/pkg"
mkdir -p "$stage"

# Client payload and launcher: /usr/lib/mouthtype-linux and /usr/bin/mouthtype-linux.
python3 -I "$root/tools/linux-desktop/install.py" --prefix /usr --destdir "$stage" >/dev/null

# Omarchy bar plugin sources, runtime files only. mouthtype-linux-setup copies them into the user's home.
plugin="$stage/usr/share/mouthtype-linux/omarchy-plugin"
while IFS= read -r -d '' file; do
    install -Dm644 "$root/tools/omarchy-plugin/$file" "$plugin/$file"
done < <(cd "$root/tools/omarchy-plugin" && find . -type f \
    ! -name 'test_*' ! -name 'tst_*' ! -name 'gen_*' ! -name '*.pyc' \
    ! -path './*-render/*' ! -path './design/gallery/*' ! -path './design/render/*' \
    ! -path '*/fixtures/*' -print0 | sort -z)
install -Dm644 "$root/packaging/Version.plist" "$stage/usr/share/mouthtype-linux/Version.plist"
chmod 755 "$plugin/control.py" "$plugin/save_dialog.py" "$plugin/install.py"

install -Dm755 "$here/mouthtype-linux-setup" "$stage/usr/bin/mouthtype-linux-setup"
install -Dm644 "$root/packaging/arch/aur/mouthtype-linux.service" "$stage/usr/lib/systemd/user/mouthtype-linux.service"

install -Dm644 "$here/lintian-overrides" "$stage/usr/share/lintian/overrides/mouthtype-linux"
chmod 755 "$stage/usr/lib/mouthtype-linux/tools/linux-desktop/run-ci.sh"
# First-run unit, enabled for every user the way `systemctl --global enable` would: a symlink in
# graphical-session.target.wants. dpkg owns the link, so remove and purge delete it with the package.
install -Dm644 "$root/tools/linux-desktop/systemd/mouthtype-linux-firstrun.service" \
    "$stage/usr/lib/systemd/user/mouthtype-linux-firstrun.service"
install -d "$stage/usr/lib/systemd/user/graphical-session.target.wants"
ln -s ../mouthtype-linux-firstrun.service \
    "$stage/usr/lib/systemd/user/graphical-session.target.wants/mouthtype-linux-firstrun.service"

doc="$stage/usr/share/doc/mouthtype-linux"
install -Dm644 "$root/THIRD_PARTY_NOTICES.md" "$doc/THIRD_PARTY_NOTICES.md"
install -Dm644 "$here/copyright.in" "$doc/copyright"
{
    printf 'mouthtype-linux (%s) unstable; urgency=low\n\n  * Development build of the Mouthtype Linux client.\n\n -- CodesWhat <80784472+scttbnsn@users.noreply.github.com>  %s\n' \
        "$version" "$(LC_ALL=C date -u -d "@$epoch" '+%a, %d %b %Y %H:%M:%S +0000')"
} | gzip -9n > "$doc/changelog.Debian.gz"
chmod 644 "$doc/changelog.Debian.gz"
for page in mouthtype-linux mouthtype-linux-setup; do
    install -d "$stage/usr/share/man/man1"
    gzip -9n -c "$here/$page.1" > "$stage/usr/share/man/man1/$page.1.gz"
    chmod 644 "$stage/usr/share/man/man1/$page.1.gz"
done

# Normalise modes and timestamps so identical sources give identical bytes.
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -exec touch -h -d "@$epoch" {} +

mkdir "$stage/DEBIAN"
size=$(du -sk --apparent-size "$stage" | cut -f1)
sed -e "s/@VERSION@/$version/" -e "s/@SIZE@/$size/" "$here/control.in" > "$stage/DEBIAN/control"
for script in postinst prerm postrm; do install -m755 "$here/$script" "$stage/DEBIAN/$script"; done
(cd "$stage" && find usr -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
chmod 644 "$stage/DEBIAN/md5sums"

deb="$output/mouthtype-linux_${version}_amd64.deb"
dpkg-deb --root-owner-group -Zxz --build "$stage" "$deb" >/dev/null
echo "$deb"
