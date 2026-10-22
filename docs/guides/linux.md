# Mouthtype on Linux

The Linux client is a development candidate for Wayland desktops with PipeWire, built first for Arch/Omarchy with
Hyprland. It records only after an explicit start, transcribes locally and delivers text to the focused window.
Details and acceptance boundaries are in [`tools/linux-desktop/README.md`](../../tools/linux-desktop/README.md).

## Install with apt

**Coming soon.** The signed apt repository is not published yet, so `sudo apt install mouthtype-linux` does not work
today. Everything below is built and tested, and goes live when the repository is hosted at `https://mouthtype.app/apt`.

For Debian 13 (trixie), Ubuntu 24.04 and newer, x86_64:

```bash
sudo install -d -m 755 /etc/apt/keyrings
sudo curl -fsSL https://mouthtype.app/apt/mouthtype-archive-keyring.gpg -o /etc/apt/keyrings/mouthtype-archive-keyring.gpg
sudo curl -fsSL https://mouthtype.app/apt/mouthtype.sources -o /etc/apt/sources.list.d/mouthtype.sources
sudo apt update
sudo apt install mouthtype-linux
mouthtype-linux-setup
```

The source setup is one time. After that, `sudo apt upgrade` updates the client. `mouthtype-linux-setup` runs as your
normal user and downloads the speech model (about 465 MiB). Before `sudo apt remove mouthtype-linux`, run
`mouthtype-linux-setup --uninstall` to remove the per-user bar widget and service link.

Hyprland is only a recommendation. Ubuntu 26.04 packages it; Debian 13 and Ubuntu 24.04 do not, so install it
yourself if you want the target-aware paste and type delivery. The Omarchy bar plugin needs Quickshell, which neither
distribution packages.

## Other installs

Arch and Omarchy use the AUR recipe in `packaging/arch/aur`. A source checkout installs with
`python3 tools/linux-desktop/install.py`.
