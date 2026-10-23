# Mouthtype on Arch/Omarchy: install guide for people and coding agents

This is the complete, ordered procedure to install the experimental Mouthtype Linux client and its Omarchy bar plugin so that dictation, the floating pill, paste delivery and optional AI cleanup all work on an Omarchy desktop (Arch Linux, Hyprland, PipeWire, x86_64). Every step has a check. An agent should run the steps in order, stop on a failed check, and never use sudo for anything except the package manager in step 1.

There is no package to install yet. An AUR recipe and a signed apt repository (Debian 13, Ubuntu 24.04 and newer) are built and tested but not published, so `yay -S` and `apt install` do not work today. Do not try them; use the source steps below. Package installs will set themselves up at the next login.

Only the source archive linked from https://mouthtype.app/linux/ (or a checkout of the Mouthtype repository) is needed. The archive must contain `tools/omarchy-plugin`; archives older than that directory install the terminal client only.

## 1. Packages

Install with the distro's signed package manager. Required: `python`, `python-pip`, `curl`, `pipewire-audio`, `ffmpeg`, `wl-clipboard`, `wtype`, `libnotify`. Optional Fast and Thorough cleanup download a checked upstream `llama-server`, so no compiler is needed; `git`, `cmake` and `base-devel` are only for the opt-in `--build-server`.

```bash
sudo pacman -S --needed python python-pip curl pipewire-audio ffmpeg wl-clipboard wtype libnotify
```

Check: `pw-record --version`, `ffprobe -version`, `wl-copy --version`, `wtype` (prints usage) and `hyprctl version` all run. `echo "$PATH" | tr : '\n' | grep -qx "$HOME/.local/bin"` must succeed; if not, add `~/.local/bin` to the session PATH (Omarchy already includes it).

## 2. Source

Download and extract the source archive, then work from the extracted directory:

```bash
curl -L -o mouthtype-source.tar.gz https://mouthtype.app/source
mkdir -p ~/src/mouthtype && tar -xzf mouthtype-source.tar.gz -C ~/src/mouthtype --strip-components=1
cd ~/src/mouthtype
```

Check: `tools/linux-desktop/install.py`, `tools/linux-desktop/setup_speech.py` and `tools/omarchy-plugin/install.py` exist. If `tools/omarchy-plugin` is missing, this archive predates the plugin and the step 3 check below will also fail, because older clients have no `file_transcription` capability. Use a newer archive or a git checkout of the repository instead.

## 3. Client

```bash
python3 tools/linux-desktop/install.py --prefix "$HOME/.local"
```

Installs `~/.local/bin/mouthtype-linux` and its payload under `~/.local/lib/mouthtype-linux`. It refuses to overwrite an existing installation; to upgrade, move the old `~/.local/lib/mouthtype-linux` and `~/.local/bin/mouthtype-linux` aside first. Nothing else on the system changes.

Check: `mouthtype-linux capabilities` prints JSON with `"interface": 1` and a `file_transcription` entry.

## 4. Setup (speech model, plugin, shortcuts)

```bash
python3 tools/linux-desktop/setup.py
```

Checks the required helpers and the Omarchy shell config before downloading anything, then downloads the pinned Parakeet model (about 465 MiB), verifies its SHA-256, creates a dedicated Python environment, writes `linux.json` and `engines.json`, runs `doctor`, installs the Omarchy plugin with its login service and binds Super+Alt+M (dictate) and Super+Shift+T (Transform Selection). Basic cleanup is on by default. Allow up to an hour on a slow connection. On a terminal it then offers Fast or Thorough cleanup; pass `--cleanup skip` to never offer it. `--shortcut toggle|hold`, `--no-autostart`, `--skip-plugin` and `--no-transform-shortcut` adjust it. `setup_speech.py --destination ...` does the speech step alone.

Check:

```bash
mouthtype-linux doctor
```

reports `checks passed` (a stopped service is a warning, not an error). Doctor also checks the microphone and says how to fix anything missing.

## 5. Omarchy plugin, with the login daemon

Step 4 already installs the plugin. To install or refresh it alone:

```bash
python3 tools/omarchy-plugin/install.py
```

Copies the plugin to `~/.config/omarchy/plugins/dstahl.mouthtype`, adds the Mouthtype widget to the right side of the bar in `~/.config/omarchy/shell.json` (after backing it up), enables the `mouthtype-linux` systemd user service so dictation starts with the graphical session and is restarted if it stops, starts it now, and restarts the Omarchy shell. Desktop notifications are set to errors-only, since the pill already shows recording and transcribing. Use `--no-autostart` to skip the login service and `--update` to refresh an existing installation.

If a `mouthtype-linux.service` user unit already exists that the installer didn't create, it stops with "An existing Mouthtype user service was not changed"; remove or rename that unit and run it again.

Check: `systemctl --user is-enabled mouthtype-linux.service` prints `enabled`; after a few seconds `mouthtype-linux status` prints JSON with `"state": "idle"`; the Mouthtype glyph is visible near the right end of the bar. Log in again if the widget or the keys are not live yet.

## 6. Delivery, microphone and shortcut

Delivery starts as recovery-only: a finished take is saved locally and nothing is typed. The first time the bar menu is opened, a card asks where words should go: paste where you are typing (recommended) or just save them. To change it later, open the menu, choose **Paste Options**, then **Paste into the active window**. Pasting uses the clipboard plus Ctrl+V (Ctrl+Shift+V in terminals, where multi-line pastes are refused) and restores the previous text clipboard. The same change without the menu:

```bash
~/.config/omarchy/plugins/dstahl.mouthtype/control.py set-config delivery paste
```

To record from a specific microphone, use Settings, General, Microphone (it also has a level test), or `control.py set-config microphone <node.name|default>`. If the chosen source is unplugged, takes fall back to the default.

The dictation key is Super+Alt+M. Change it under **Change Dictation Shortcut…**: press-to-toggle or hold-to-talk on any letter, digit, F-key, named key or a lone modifier such as Right Ctrl. Without the menu, for example hold-to-talk on F8:

```bash
~/.config/omarchy/plugins/dstahl.mouthtype/control.py set-shortcut hold F8
```

A key that Hyprland already binds is refused, and the previous binding file is backed up and restored if Hyprland rejects the change.

Check: `~/.config/omarchy/plugins/dstahl.mouthtype/control.py state` shows `"delivery_mode": "paste"` under `config` once paste is chosen, and `"shortcut"` is `toggle` or `hold`.

## 7. First take

Press the shortcut, say a sentence, press it again (or release the hold key). The pill at the bottom of the focused display shows the level while recording, a wave while transcribing, then a short note. Basic cleanup runs by default, so the text comes back tidied. With paste delivery on it is pasted into the active window; it is always also saved and readable with `mouthtype-linux list` and `mouthtype-linux recover ID`.

Check: `mouthtype-linux list` shows one take with `"transcript": true`.

## 8. Optional: Fast and Thorough AI cleanup

From the menu, **Cleanup** → **Prepare Fast cleanup…** (about 480 MB model plus a pinned upstream `llama-server` of about 17 MB, checksum verified, nothing compiled) or **Prepare Thorough cleanup…** (about 2.5 GB). A running model download can be cancelled from the menu. Without the menu:

```bash
python3 tools/linux-desktop/setup_cleanup.py --destination "$HOME/.local/share/mouthtype/cleanup-candidate" --level fast
```

Add `--level thorough` for both. `--build-server` compiles `llama-server` locally instead and is the only path that needs `git`, `cmake` and `base-devel`. Then choose Fast or Thorough under **Cleanup**; the service restarts with the model loaded. Fast (S1-mini) answers in well under a second for ordinary takes on a modern CPU; Thorough (Qwen3 4B) takes several seconds and needs about 5 GiB of memory. When a model is too slow or changes the meaning, the Basic text is kept and the pill notes it.

Check: `mouthtype-linux --config "$HOME/.local/share/mouthtype/speech-candidate/linux.json" doctor` reports `cleanup_model` as OK, and `mouthtype-linux status` shows `"cleanup": {"level": "fast", ...}` with a model state of `ready`.

## 9. Optional: transcribe an audio file

**Transcribe Audio File…** in the menu opens the desktop file chooser for one WAV, AIFF or M4A file of up to 10 minutes and 512 MB, then shows the raw result with Copy and Save Text. Without the menu: `mouthtype-linux import /path/to/file.m4a`, then `mouthtype-linux import-status` and `mouthtype-linux import-result`.

## Removing

Run `mouthtype-linux-setup --uninstall` first (for a source install, `python3 tools/linux-desktop/setup.py --uninstall`). It removes the bar widget, the shortcuts and the login service link; models and recordings stay unless you add `--purge`. For a source install, then remove the client:

```bash
python3 tools/linux-desktop/install.py --uninstall --prefix "$HOME/.local"
```

Models and recordings live under `~/.local/share/mouthtype` and `~/.local/state/mouthtype`; delete them only if you no longer want them. Restart the shell with `omarchy-restart-shell` if the widget is still showing.

## Limits worth knowing

Linux cannot detect password fields, so paste and type delivery go wherever the cursor is. Insertion is not verified; the saved text is always available. Lone modifier keys fire inside their own shortcuts (Right Ctrl as hold-to-talk also triggers during Ctrl+C with that key). The Hi-Fi pill is drawn at Hyprland scale 1; other scales were not checked. Everything runs locally; nothing is uploaded.
