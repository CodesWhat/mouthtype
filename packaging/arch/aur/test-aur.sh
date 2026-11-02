#!/usr/bin/env bash
# Build and check the AUR package in a disposable archlinux container. Run as root (the script makes a build
# user), from anywhere:
#
#   bash ~/scripts/nas-docker.sh --exec ... archlinux:latest bash packaging/arch/aur/test-aur.sh
#
# The repo checkout must be mounted or copied in; set MOUTHTYPE_REPO to its path (default: this script's repo).
# It changes the container it runs in, so do not run it on a machine you care about.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root inside a disposable archlinux container" >&2; exit 2; }
repo=$(realpath "${MOUTHTYPE_REPO:-$(dirname "$0")/../../..}")
pkg=mouthtype-linux-git
step() { printf '\n== %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

step "prerequisites"
# Container runtimes often block the syscalls pacman's download sandbox needs; this container is disposable.
sed -i "s/^#DisableSandboxSyscalls/DisableSandboxSyscalls/" /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel git namcap sudo python >/dev/null
id builder >/dev/null 2>&1 || useradd -m builder
echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

step "stage sources"
work=/home/builder/aur
rm -rf "$work"; mkdir -p "$work"
cp "$repo"/packaging/arch/aur/{PKGBUILD,.SRCINFO,mouthtype-linux.install,mouthtype-linux.service,mouthtype-linux-setup} "$work"/
# Local checkout as the git source: copy the tree and commit it in a throwaway repo, so uncommitted work builds too.
src=/home/builder/src.git
rm -rf "$src"; mkdir -p "$src"
cp -a "$repo"/. "$src"/
rm -rf "$src/.git" "$src/.claude"
chown -R builder:builder /home/builder
sudo -u builder bash -ec "
    cd '$src' && git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm test
    cd '$work'
    # Same PKGBUILD, source swapped to the local checkout (the only edit).
    sed -i 's|git+https://github.com/CodesWhat/mouthtype.git|git+file://$src|' PKGBUILD
    makepkg -si --noconfirm
"

step "assert installed files"
files=$(pacman -Ql "$pkg")
for want in \
    /usr/bin/mouthtype-linux \
    /usr/lib/systemd/user/graphical-session.target.wants/mouthtype-linux-firstrun.service \
    /usr/share/mouthtype-linux/omarchy-plugin/; do
    grep -qF " $want" <<<"$files" || fail "$pkg does not own $want"
done
echo "ok: expected paths owned"

step "namcap"
built=$(ls "$work"/*.pkg.tar.zst | head -1)
nc=$(sudo -u builder bash -c "cd '$work' && namcap PKGBUILD; namcap '$built'" 2>&1 || true)
echo "$nc"
if grep -E ' E: ' <<<"$nc"; then fail "namcap reported errors"; fi
echo "namcap warnings:"; grep -E ' W: ' <<<"$nc" || echo "  none"

step "remove"
pacman -R --noconfirm "$pkg"
if [ -e /usr/lib/mouthtype-linux ] && [ -n "$(find /usr/lib/mouthtype-linux 2>/dev/null)" ]; then
    find /usr/lib/mouthtype-linux; fail "files remain under /usr/lib/mouthtype-linux"
fi
echo "ok: removed clean"
