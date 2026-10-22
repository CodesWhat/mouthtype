# Linux

Linux support is experimental. There's no supported Linux desktop release, and the only install that works today is from source.

> [!WARNING]
> Experimental. The first target (Arch or Omarchy on x86_64, with Hyprland and PipeWire) has run the full flow on one desk. Wider hardware, HiDPI, multi-monitor and other distros haven't been tried. Container and headless checks don't establish microphone or Hyprland support.

## What exists

The source includes a daemon and CLI aimed at Linux x86_64 on Arch or Omarchy, with Hyprland and PipeWire.

| Feature | State |
| --- | --- |
| Cleanup | Basic is on by default and is deterministic. Fast and Thorough run local models on the CPU after an explicit prepare step. Thorough is Qwen3 4B here, not the Mac model. |
| Delivery | Recovery-only by default: a take is saved and nothing is pasted. The Omarchy plugin asks on first open whether to paste where you're typing. Automatic typing is an opt-in. |
| Spellings and phrases | Supported. |
| File transcription | One WAV, AIFF or M4A at a time, with your distro's `ffmpeg`. |
| Live word previews | Not available. |
| Secure-field detection | Not available. Linux can't tell password fields apart, so paste goes wherever the cursor is. |
| Insertion verification | Not available. |

## Where Linux stands

What ran on one Arch/Omarchy desk (Hyprland 0.56, PipeWire): microphone takes, the pill, paste delivery, file import and local cleanup. What hasn't: HiDPI, multi-monitor, other distros and other compositors. Automated Ubuntu and Arch checks use synthetic audio and headless Wayland, so they don't count as desktop acceptance.

## Install

There's no package to install yet.

- **Arch and Omarchy (AUR):** not published. The recipe is in `packaging/arch/aur` and builds locally.
- **Debian and Ubuntu (apt):** coming soon, see below.
- **Source:** works today, and is the fallback until a package is live.

The source archive is at [mouthtype.app/source](https://mouthtype.app/source). From a checkout or the archive:

```bash
python3 tools/linux-desktop/install.py --prefix "$HOME/.local"
python3 tools/linux-desktop/setup.py
```

`setup.py` prepares the speech model (about 465 MiB), installs the Omarchy bar plugin with its login service and binds the shortcuts. A package install does the same on its own at your next login.

## First run

Package installs set themselves up. Log in again and the first-run unit downloads the speech model, adds the bar widget and binds Super+Alt+M (dictate) and Super+Shift+T (Transform Selection). It shows progress as a notification. If it fails it retries at the next login, up to three times, and `mouthtype-linux-setup` is the manual repair path.

Press Super+Alt+M, speak, and press it again. Basic cleanup is already on, so the text comes back tidied. Delivery starts as recovery-only, so the take lands under Recent takes on Home. The first time you open the bar menu, a card asks where your words should go: paste where you're typing (recommended), or just save them. You can change it later in Paste Options.

## Better cleanup (optional)

Fast and Thorough clean up more than Basic. They need a one-time prepare step that downloads the model and the pinned upstream `llama-server` release (about 17 MB, checksum verified). Nothing is compiled. `mouthtype-linux-setup --cleanup fast --build-server` builds it locally instead, which needs git, cmake and a C++ toolchain. See the cleanup section of the [setup guide](../../tools/linux-desktop/README.md). If a model isn't ready or times out, you get the Basic text.

## Check and remove

`mouthtype-linux doctor` reports what's missing and how to fix it. Before you remove the package, run `mouthtype-linux-setup --uninstall` to take out the bar widget, the shortcuts and the login service link. Models and recordings stay unless you add `--purge`.

## Guides

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
