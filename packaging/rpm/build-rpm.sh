#!/usr/bin/env bash
# Build mouthtype-linux and mouthtype-linux-desktop rpms with rpmbuild. No network, no third-party tools.
#
#   bash packaging/rpm/build-rpm.sh --output DIR [--version 0.3.0-1]
#
# Without --version the package is a snapshot: <Version.plist>~git<commit-time>.<rev>-1, which sorts below
# the matching stable <Version.plist>-1. Run it on Fedora (needs rpmbuild, python3, python3-rpm-macros, tar, gzip).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
here="$root/packaging/rpm"
output=
version=
while [ $# -gt 0 ]; do
    case "$1" in
        --output) output=${2:?--output needs a directory}; shift 2 ;;
        --version) version=${2:?--version needs a value}; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$output" ] || { echo "usage: build-rpm.sh --output DIR [--version VERSION]" >&2; exit 2; }

base=$(python3 -I -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],'rb'))['CFBundleShortVersionString'])" "$root/packaging/Version.plist")
if git -C "$root" rev-parse HEAD >/dev/null 2>&1; then
    epoch=$(git -C "$root" show -s --format=%ct HEAD)
    rev=$(git -C "$root" rev-parse --short=12 HEAD)
else
    epoch=${SOURCE_DATE_EPOCH:-$(date +%s)}
    rev=nogit
fi
[ -n "$version" ] || version="${base}~git${epoch}.${rev}-1"
case "$version" in [0-9]*-[0-9]*) ;; *) echo "invalid version (want VERSION-RELEASE): $version" >&2; exit 2 ;; esac
rpm_version=${version%-*}
rpm_release=${version##*-}
export SOURCE_DATE_EPOCH=$epoch

command -v rpmbuild >/dev/null || { echo "rpmbuild not found (dnf install rpm-build python3-rpm-macros)" >&2; exit 2; }
mkdir -p "$output"
output=$(cd "$output" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
top="$work/rpmbuild"
mkdir -p "$top"/{SOURCES,SPECS,BUILD,RPMS,SRPMS,BUILDROOT}

# Source tarball: only what the spec installs from, with a fixed order, owner and mtime.
name="mouthtype-linux-$rpm_version"
src="$work/$name"
mkdir -p "$src/tools" "$src/packaging/debian" "$src/packaging/arch/aur"
cp -R "$root/tools/linux-desktop" "$root/tools/linux-engine-proof" "$root/tools/linux-qt" "$root/tools/omarchy-plugin" "$src/tools/"
cp "$root/LICENSE" "$root/THIRD_PARTY_NOTICES.md" "$src/"
cp "$root/packaging/debian/mouthtype-linux-setup" "$root/packaging/debian/mouthtype-desktop" \
   "$root"/packaging/debian/*.1 "$root/packaging/debian/app.mouthtype.Mouthtype.Settings.desktop" "$src/packaging/debian/"
cp "$root/packaging/arch/aur/mouthtype-linux.service" "$src/packaging/arch/aur/"
cp "$root/packaging/Version.plist" "$src/packaging/"
find "$src" -name __pycache__ -type d -prune -exec rm -rf {} +
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -C "$work" -czf "$top/SOURCES/$name.tar.gz" "$name"

sed -e "s/@VERSION@/$rpm_version/g" -e "s/@RELEASE@/$rpm_release/g" \
    -e "s/@CHANGELOG_DATE@/$(LC_ALL=C date -u -d "@$epoch" '+%a %b %d %Y')/" \
    "$here/mouthtype-linux.spec.in" > "$top/SPECS/mouthtype-linux.spec"

rpmbuild -bb --define "_topdir $top" --define "source_date_epoch_from_changelog 0" \
    --define "clamp_mtime_to_source_date_epoch 1" --define "use_source_date_epoch_as_buildtime 1" \
    "$top/SPECS/mouthtype-linux.spec" >&2
find "$top/RPMS" -name '*.rpm' -exec cp {} "$output/" \;
ls "$output"/*.rpm
