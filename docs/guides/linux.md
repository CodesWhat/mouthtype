# Linux

Linux support is experimental and source-only. There's no supported Linux desktop release.

> [!WARNING]
> Experimental and source-only. The first target (Arch or Omarchy on x86_64, with Hyprland and PipeWire) has had component checks, but physical acceptance is still open. Container and headless checks don't establish microphone or Hyprland support.

## What exists

The source includes a daemon and CLI aimed at Linux x86_64 on Arch or Omarchy, with Hyprland and PipeWire.

| Feature | State |
| --- | --- |
| Delivery | Recovery-only by default, with no clipboard or key changes. Automatic typing and paste are explicit opt-ins. |
| Cleanup | Off by default. Basic is deterministic. Fast and Thorough run local models on the CPU after an explicit prepare step. Thorough is Qwen3 4B here, not the Mac model. |
| Spellings and phrases | Supported. |
| File transcription | One WAV, AIFF or M4A at a time, with your distro's `ffmpeg`. |
| Live word previews | Not available. |
| Secure-field detection | Not available. |
| Insertion verification | Not available. |

## Where to start

The source archive is at [mouthtype.app/source](https://mouthtype.app/source). It includes the guides below, which are also copied into these docs.

<!-- docs:cards -->

- [Linux desktop setup and testing](../../tools/linux-desktop/README.md): `tools/linux-desktop/README.md`.
- [Omarchy plugin](../../tools/omarchy-plugin/README.md): `tools/omarchy-plugin/README.md`. It adds a bar menu, a floating pill and a choice of toggle or hold shortcut. Its installer enables a login service unless you pass `--no-autostart`.
- [Agent install checklist](https://mouthtype.app/linux/agent-install.md): an ordered install checklist for people and coding agents.

The speech-preparation helper downloads pinned model files, verifies their hashes and builds a dedicated environment. It doesn't record, register shortcuts or start a service.

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
