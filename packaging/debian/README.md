# Debian and Ubuntu package

Builds `mouthtype-linux_<version>_amd64.deb` and a signed static apt repository. Mirrors the Arch package in
`packaging/arch/aur`: same `/usr` layout, same systemd user unit, same `mouthtype-linux-setup` helper (this copy calls
`python3`, since Debian has no `python` command).

Status: built and tested, **not published**. The docs mark `apt install` as coming soon until step 5 below is done.

## Why dpkg-deb and not nfpm

`build-deb.sh` uses plain `dpkg-deb`. The package needs hand-written maintainer scripts, a DEP-5 copyright file,
man pages and lintian overrides, and `dpkg-deb --root-owner-group` handles all of that with nothing to download.
nfpm would add a pinned third-party binary to the supply chain of a package that is only a Python tree. Output is
reproducible for a given commit (`SOURCE_DATE_EPOCH`, sorted file lists, normalised modes).

## What it installs

- `/usr/bin/mouthtype-linux`, `/usr/lib/mouthtype-linux/...` (same payload as `install.py --prefix /usr`)
- `/usr/bin/mouthtype-linux-setup`
- `/usr/lib/systemd/user/mouthtype-linux.service` (not enabled; `mouthtype-linux-setup` does that per user)
- `/usr/share/mouthtype-linux/omarchy-plugin/...`
- docs, copyright, man pages, lintian overrides

Depends: `python3 (>= 3.10)` (the minimum `doctor` enforces), `python3-venv` (setup builds the speech venv),
`curl`, `pipewire-audio`, `wl-clipboard`, `wtype`, `libnotify-bin`, `ffmpeg`. Recommends `hyprland`, suggests
`quickshell`. Those package names exist on Ubuntu 24.04, Ubuntu 26.04 and Debian 13. Hyprland exists only on 26.04
(0.53.3); Quickshell is in none of them. `postinst`, `prerm` and `postrm` point at `mouthtype-linux-setup`.

## Build and test

Run on Debian or Ubuntu, or in a container:

```bash
bash packaging/debian/build-deb.sh --output /tmp/debs                 # snapshot version
bash packaging/debian/build-deb.sh --output /tmp/debs --version 0.4.0-1  # release version
lintian --pedantic /tmp/debs/mouthtype-linux_*.deb
bash packaging/debian/test-install.sh /tmp/debs/mouthtype-linux_*.deb   # root, disposable container only
bash packaging/debian/test-apt-repo.sh /path/to/repo                    # signed repo flow, throwaway key
```

On the NAS testbed, mount a synced checkout read-only and a named volume for output (see
`~/code/scttbnsn/localhost/docs/nas-docker.md`), and use a distinct volume name.

## Make the real signing key (once)

Do this on your Mac, never in CI and never in this repo.

```bash
export GNUPGHOME=$(mktemp -d)
gpg --quick-generate-key 'Mouthtype Archive <hello@mouthtype.app>' ed25519 sign 3y
gpg --list-secret-keys --keyid-format long      # note the fingerprint
gpg --armor --export-secret-keys <FPR> > mouthtype-archive-private.asc
gpg --gen-revoke <FPR> > mouthtype-archive-revoke.asc
```

Store `mouthtype-archive-private.asc`, the passphrase and `mouthtype-archive-revoke.asc` in 1Password (a Secure Note
or document in the CodesWhat vault) and delete the plain files and the temporary `GNUPGHOME`. Do not commit them,
and do not paste them into a GitHub Actions secret unless you later decide to sign in CI. To sign, import the key
into a temporary `GNUPGHOME`, run the script, and delete that directory. Only the public half is published. The
macOS Keychain is a fine alternative home for the passphrase.

Pick an expiry you will remember (3 years above) and extend it before it lapses: a lapsed key makes every client's
`apt update` fail until they fetch the new keyring.

## Publish

1. Build the release `.deb` (`--version <Version.plist>-1`), from a tagged commit.
2. Import the signing key into a temporary `GNUPGHOME` (from 1Password) and build the repo, keeping the previous
   pool so old versions stay installable:

   ```bash
   bash packaging/debian/build-apt-repo.sh --output ./apt --key <FPR> --deb /tmp/debs/mouthtype-linux_*.deb
   ```

3. Check it yourself: `find apt -type f`, and run `packaging/debian/test-apt-repo.sh` again on the same commit.
4. Upload the whole `apt/` directory so it is served at `https://mouthtype.app/apt/` (static files, no server
   logic). Fetch `https://mouthtype.app/apt/dists/stable/InRelease` and `.../mouthtype.sources` to confirm.
5. On a clean Debian or Ubuntu container follow the commands in `docs/guides/linux.md`, then change "coming soon" to a
   normal install section in `docs/guides/linux.md` and `tools/linux-desktop/README.md`.

Layout:

```
apt/dists/stable/{Release,InRelease,Release.gpg}
apt/dists/stable/main/binary-amd64/Packages{,.gz,.xz}
apt/pool/main/m/mouthtype-linux/*.deb
apt/mouthtype-archive-keyring.gpg   apt/mouthtype-archive-keyring.asc   apt/mouthtype.sources
```

## Open items before a real `apt install mouthtype-linux`

- Hosting at `mouthtype.app/apt` and the real signing key do not exist yet.
- Hyprland is packaged only on Ubuntu 26.04. On Ubuntu 24.04 and Debian 13 paste and type delivery need a
  self-installed Hyprland.
- Quickshell is packaged by neither, so the Omarchy bar plugin has no host there.
- `mouthtype-linux-setup`, `doctor` and the speech venv are Arch-flavoured in places (messages name Arch package
  names such as `pipewire-audio` and `libnotify`). The apt package pulls the real Debian dependencies, so this only
  matters if someone removes one.
- The speech engine is pinned to `sherpa-onnx` 1.13.8 wheels; setup was not run end to end here because it
  downloads a 465 MiB model.
