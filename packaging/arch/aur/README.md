# AUR package: mouthtype-linux-git

This directory holds a publish-ready `PKGBUILD` and `mouthtype-linux.install` for the
development client. It is not published. `PKGBUILD` builds from the GitHub repository,
installs the client under `/usr`, the Omarchy bar plugin under
`/usr/share/mouthtype-linux/omarchy-plugin`, a systemd user unit under
`/usr/lib/systemd/user`, and the `mouthtype-linux-setup` helper.

User flow once published: `yay -S mouthtype-linux-git` (or `omarchy-pkg-add` through the AUR
menu), then log in. The package enables `mouthtype-linux-firstrun.service` for every user
(a symlink in `graphical-session.target.wants`), which sets up speech, the bar plugin and the two
shortcuts at the first graphical login and reports through notifications. `mouthtype-linux-setup`
remains the manual and repair path; `systemctl --user start mouthtype-linux-firstrun` runs it
without logging out. Removal: `mouthtype-linux-setup --uninstall`, then
`sudo pacman -R mouthtype-linux-git`.

`packaging/arch/PKGBUILD.in` and `scripts/prepare-linux-arch.py` stay as the CI-tested local
bundle. They are separate on purpose and do not carry the plugin.

## Checks

- `bash packaging/arch/aur/test-aur.sh` builds the package from the local checkout in a disposable
  `archlinux:latest` container (run as root there), installs it, asserts the client, the first-run unit link
  and the plugin are owned by the package, runs `namcap` (errors fail, warnings print), then removes it and
  asserts nothing is left under `/usr/lib/mouthtype-linux`. On the NAS testbed:
  `bash ~/scripts/nas-docker.sh run --rm -v "$(bash ~/scripts/nas-docker.sh --sync .)":/repo:ro -e MOUTHTYPE_REPO=/repo archlinux:latest bash /repo/packaging/arch/aur/test-aur.sh`
- `bash packaging/arch/aur/check-srcinfo.sh` regenerates `.SRCINFO` and fails on a diff. Run it as a normal
  user on Arch (makepkg refuses root). Regenerate with `makepkg --printsrcinfo > .SRCINFO` after any
  `PKGBUILD` change.

## Branch

`_branch` is `${MOUTHTYPE_BRANCH:-main}`. The public package tracks `main`, so the Linux client has to be
on `main` before this is published. To build another branch: `MOUTHTYPE_BRANCH=feat/linux-parity makepkg -si`.

## Publishing steps (when you want it public)

`bash packaging/arch/aur/publish-aur.sh` prints these steps with the paths filled in. It pushes nothing.

1. Run `test-aur.sh` and `check-srcinfo.sh`; both must exit 0. Confirm the repository is public and `main`
   carries the Linux client.
2. Create an AUR account, add your SSH key, then
   `git clone ssh://aur@aur.archlinux.org/mouthtype-linux-git.git`.
3. Copy `PKGBUILD`, `.SRCINFO`, `mouthtype-linux.install`, `mouthtype-linux.service` and
   `mouthtype-linux-setup` into that clone.
4. Commit and push to the `master` branch of the AUR repo.
5. Check `https://aur.archlinux.org/rpc/v5/info?arg[]=mouthtype-linux-git` returns `resultcount: 1`.
6. Once a tagged Linux release exists, add a stable `mouthtype-linux` package pinned to the tag
   with a real checksum, and keep `-git` as the development variant.
7. The first-run logic is in the client (`tools/linux-desktop/firstrun.py`); a package only installs
   `tools/linux-desktop/systemd/mouthtype-linux-firstrun.service` and enables it for all users.
8. Keep the plugin copy in step: `post_upgrade` tells users to re-run `mouthtype-linux-setup`.
