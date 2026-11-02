#!/usr/bin/env bash
# Prints the steps to publish mouthtype-linux-git to the AUR. It does not push anything: publishing needs an
# AUR account and a maintainer decision.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cat <<MSG
Publish mouthtype-linux-git to the AUR (nothing below has been run for you):

  0. Pre-flight, from a clean Arch container or chroot, in the repo root:
       bash $here/test-aur.sh
       bash $here/check-srcinfo.sh
     Both must exit 0. Confirm the default branch in PKGBUILD (_branch) carries the Linux client.

  1. AUR account with your SSH public key added at https://aur.archlinux.org/account/
  2. git clone ssh://aur@aur.archlinux.org/mouthtype-linux-git.git /tmp/aur-mouthtype-linux-git
  3. cp $here/PKGBUILD $here/.SRCINFO $here/mouthtype-linux.install \\
        $here/mouthtype-linux.service $here/mouthtype-linux-setup /tmp/aur-mouthtype-linux-git/
  4. cd /tmp/aur-mouthtype-linux-git && makepkg --printsrcinfo | diff - .SRCINFO   # no output expected
  5. git add PKGBUILD .SRCINFO mouthtype-linux.install mouthtype-linux.service mouthtype-linux-setup
     git commit -m "Initial import: mouthtype-linux-git"
     git push origin master
  6. Verify: curl -s 'https://aur.archlinux.org/rpc/v5/info?arg[]=mouthtype-linux-git'   # resultcount 1
     Then on a real desk: yay -S mouthtype-linux-git, log in again, first take works.
MSG
