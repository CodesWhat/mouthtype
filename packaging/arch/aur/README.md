# AUR package: mouthtype-linux-git

This directory holds a publish-ready `PKGBUILD` and `mouthtype-linux.install` for the
development client. It is not published. `PKGBUILD` builds from the GitHub repository,
installs the client under `/usr`, the Omarchy bar plugin under
`/usr/share/mouthtype-linux/omarchy-plugin`, a systemd user unit under
`/usr/lib/systemd/user`, and the `mouthtype-linux-setup` helper.

User flow once published: `yay -S mouthtype-linux-git` (or `omarchy-pkg-add` through the AUR
menu), then `mouthtype-linux-setup`. Removal: `mouthtype-linux-setup --uninstall`, then
`sudo pacman -R mouthtype-linux-git`.

`packaging/arch/PKGBUILD.in` and `scripts/prepare-linux-arch.py` stay as the CI-tested local
bundle. They are separate on purpose and do not carry the plugin.

## Publishing steps (when you want it public)

1. Confirm `_branch` in `PKGBUILD` names the branch that carries the Linux client (today
   `feat/linux-parity`), and that the repository is public.
2. Create an AUR account, add your SSH key, then
   `git clone ssh://aur@aur.archlinux.org/mouthtype-linux-git.git`.
3. Copy `PKGBUILD` and `mouthtype-linux.install` into that clone. Add a `.gitignore` for build output.
4. In a clean Arch container or chroot: `makepkg -f`, `namcap PKGBUILD *.pkg.tar.zst`,
   `sudo pacman -U` the package, then `sudo pacman -R` it.
5. `makepkg --printsrcinfo > .SRCINFO`, commit `PKGBUILD`, `mouthtype-linux.install` and `.SRCINFO`,
   push to the `master` branch of the AUR repo.
6. Once a tagged Linux release exists, add a stable `mouthtype-linux` package pinned to the tag
   with a real checksum, and keep `-git` as the development variant.
7. Keep the plugin copy in step: `post_upgrade` tells users to re-run `mouthtype-linux-setup`.
