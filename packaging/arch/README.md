# Local Arch test package

This bundle builds an x86_64 development candidate with normal makepkg. It is
not an AUR package or an official Arch/Omarchy release. It contains a local
source archive, resolved PKGBUILD, integrity manifest and source receipt.
No GitHub credentials or public source endpoint are required to build it.

In this bundle directory, verify with `sha256sum -c SHA256SUMS.txt`, then run
`makepkg --cleanbuild --check` as your ordinary user. Arch's normal base-devel
and the declared dependencies must already be available. The build never
downloads models, starts the client or installs dependencies. Install
the resulting `.pkg.tar.zst` with your normal `pacman -U` operation. Leave
your effective package-signature policy unchanged. An unsigned test package
is usable only when that existing policy permits local unsigned packages.
If it requires a signature, keep using the source installer instead.

The installed command is `/usr/bin/mouthtype-linux`. An older manually
installed command under `~/.local/bin` can shadow it; check the selected path
or use the absolute command. The package does not delete that older install.
Pacman owns the new `/usr` payload and can upgrade/remove it normally.

Reuse your existing speech environment and client configuration. For a first
setup, run `python /usr/lib/mouthtype-linux/tools/linux-desktop/setup_speech.py --destination "$HOME/.local/share/mouthtype/speech-candidate"`.
The destination must be new. Preparation verifies pinned public model data and
creates a private Python environment without recording or starting a service.
It prints the foreground serve command. No model, configuration or recovery
file belongs inside `/usr` or this source bundle.

Use `/usr/bin/mouthtype-linux --config /path/to/linux.json serve` explicitly
when ready. No services, autostart, shortcuts or compositor configuration are
installed. Recovery-only delivery remains the default. Optional Hyprland,
wtype and libnotify packages enable the existing adapter/feedback features;
this package does not grant permissions or change security policy.

Runtime instructions and acceptance boundaries are in
`/usr/lib/mouthtype-linux/tools/linux-desktop/README.md`. Physical microphone,
hold/toggle and native Hyprland/Omarchy typing still need coordinated testing.
Package build/install checks do not certify them. Removing the package leaves
your separately prepared models, private configuration and recovery untouched.

The hosted Arch job builds with ordinary-user makepkg, then installs/removes
the package inside the disposable runner with unchanged pacman policy. It
checks the real installed command, payload hashes, portable Unicode tests,
package contents and user-data preservation. Those claims require the fetched
result for the exact candidate; this README alone is not acceptance evidence.

References: [Arch PKGBUILD](https://man.archlinux.org/man/PKGBUILD.5.en),
[makepkg](https://man.archlinux.org/man/makepkg.8.en), and
[pacman signature policy](https://man.archlinux.org/man/pacman.conf.5.en).
Omarchy's current [stable template](https://github.com/omacom/omarchy/blob/cce8b1c971df64a7610b818ff8819e4bea04584a/default/pacman/pacman-stable.conf)
allows unsigned local packages; the actual operator's effective policy takes
precedence and is never changed by this bundle.
