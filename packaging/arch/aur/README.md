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
  asserts nothing is left under `/usr/lib/mouthtype-linux`. On the NAS testbed, run
  `bash packaging/arch/aur/nas-test.sh`: it stages the checkout with `nas-docker.sh --sync`, runs one uniquely
  named `--rm` container from `archlinux:latest`, and removes it on exit. It never touches local Docker. A full run
  installs about 150 MiB of build dependencies. The build runs as a normal user inside a throwaway container,
  which is what `makepkg -si` needs. It isn't `devtools`' `extra-x86_64-build` (that needs nspawn and bind mounts
  the NAS engine can't give), so "clean chroot" here means a fresh container per run.
- `-git` against a release PKGBUILD: the `-git` package takes its version from the commit count and tracks a
  branch, so every build differs and nothing is pinned. A release `mouthtype-linux` PKGBUILD would pin a tag and a
  checksum, give AUR users a reproducible build and upgrades by version, and cost a `.SRCINFO` and checksum bump
  per release. It needs a tagged public release first, so only `-git` exists for now.
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
