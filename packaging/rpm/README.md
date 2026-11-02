# Fedora rpm package

Builds `mouthtype-linux-<version>.x86_64.rpm` and `mouthtype-linux-desktop-<version>.noarch.rpm` with plain `rpmbuild`.
Same payload layout and split as `packaging/debian` (`install.py --prefix /usr --destdir`, the Omarchy plugin sources
under `/usr/share/mouthtype-linux`, the same user units, setup helper, man pages and desktop entries).

Status: built and tested in a `fedora:44` container, **not published** (no COPR repo yet).

## Build

```sh
bash packaging/rpm/build-rpm.sh --output DIR [--version 0.5.0-1]
```

Run it on Fedora with `rpm-build` and `python3-rpm-macros`. Without `--version` it makes a snapshot,
`<Version.plist>~git<commit-time>.<rev>-1`, which sorts below the matching stable release. The script tars the files
the spec installs from with a fixed order, owner and mtime, fills `mouthtype-linux.spec.in` and runs `rpmbuild -bb`.
`%check` runs `test_spellings.py` against the staged payload.

## Test

```sh
bash packaging/rpm/test-install.sh CORE.rpm [DESKTOP.rpm]   # as root, in a disposable fedora:44 container
```

Runs rpmlint (errors fail, `no-binary` is allowed because the core package is pinned to x86_64 like the deb), `dnf
install`, a file check, an offscreen launch of `mouthtype-desktop`, `mouthtype-linux doctor --json` (exit 0 or 2, 2
meaning setup is pending), `dnf remove` with a leftovers check, and a reinstall.

## Dependencies

`mouthtype-linux` requires `python3 >= 3.10`, `python3-jeepney`, `curl`, and the commands `pw-record`, `notify-send` and
`ffmpeg` as file dependencies, so either ffmpeg-free or the RPM Fusion ffmpeg satisfies it. Recommends `wl-clipboard` and
`wtype`, suggests `quickshell` and `mouthtype-linux-desktop`.

`mouthtype-linux-desktop` requires the matching core version, `python3-pyside6`, `python3-gobject`, `at-spi2-core`,
`qt6-qtdeclarative`, `qt6-qtsvg` and `xdg-desktop-portal >= 1.19`. Recommends the portal backend for the installed
desktop (`xdg-desktop-portal-gnome` with gnome-shell, `xdg-desktop-portal-kde` with plasma-workspace), `layer-shell-qt`
(KDE pill) and `gnome-shell-extension-appindicator` (GNOME tray).

## Running the container test on the NAS testbed

The testbed kernel (4.4.x) makes GNU tar 1.35 in `fedora:44` fail when it extracts nested directories ("Function not
implemented"), which breaks rpm's `%prep` and rpmlint. In that container only, install `bsdtar`, put
`%__tar /usr/bin/bsdtar` in `~/.rpmmacros` for the build, and `ln -sf /usr/bin/bsdtar /usr/bin/tar` before
`test-install.sh`. A normal Fedora host or GitHub runner needs none of this.
