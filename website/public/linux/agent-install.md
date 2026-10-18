# Mouthtype on Arch/Omarchy: install guide for people and coding agents

This is the complete, ordered procedure to install the experimental Mouthtype Linux client and its Omarchy bar plugin so that dictation, the floating pill, paste delivery and optional AI cleanup all work on an Omarchy desktop (Arch Linux, Hyprland, PipeWire, x86_64). Every step has a check. An agent should run the steps in order, stop on a failed check, and never use sudo for anything except the package manager in step 1.

Only the source archive linked from https://mouthtype.app/linux/ (or a checkout of the Mouthtype repository) is needed. The archive must contain `tools/omarchy-plugin`; archives older than that directory install the terminal client only.

## 1. Packages

Install with the distro's signed package manager. Required: `python`, `python-pip`, `curl`, `pipewire-audio`, `ffmpeg`, `wl-clipboard`, `wtype`, `libnotify`. For optional AI cleanup models: `git`, `cmake`, `base-devel`.

```bash
sudo pacman -S --needed python python-pip curl pipewire-audio ffmpeg wl-clipboard wtype libnotify git cmake base-devel
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

## 4. Speech model

```bash
python3 tools/linux-desktop/setup_speech.py --destination "$HOME/.local/share/mouthtype/speech-candidate"
```

Downloads the pinned Parakeet model (about 465 MiB), verifies its SHA-256, creates a dedicated Python environment and writes `linux.json` and `engines.json` in that directory. The destination must be new. Allow up to an hour on a slow connection.

Check: the command prints the foreground launch command and exits 0, and

```bash
mouthtype-linux --config "$HOME/.local/share/mouthtype/speech-candidate/linux.json" doctor
```

reports `checks passed` (a stopped service is a warning, not an error).

## 5. Omarchy plugin, with the login daemon

```bash
python3 tools/omarchy-plugin/install.py
```

Copies the plugin to `~/.config/omarchy/plugins/dstahl.mouthtype`, adds the Mouthtype widget to the right side of the bar in `~/.config/omarchy/shell.json` (after backing it up), enables the `mouthtype-linux` systemd user service so dictation starts at login and is restarted if it stops, starts it now, and restarts the Omarchy shell. Use `--no-autostart` to skip the login service and `--update` to refresh an existing installation.

If a `mouthtype-linux.service` user unit already exists that the installer didn't create, it stops with "An existing Mouthtype user service was not changed"; remove or rename that unit and run it again.

Check: `systemctl --user is-enabled mouthtype-linux.service` prints `enabled`; after a few seconds `mouthtype-linux status` prints JSON with `"state": "idle"`; the Mouthtype glyph is visible near the right end of the bar.

## 6. Delivery and shortcut

By default a finished take is saved locally and nothing is typed. To paste into the window that was active when dictation started, open the menu, choose **Paste Options**, then **Paste into the active window**. Pasting uses the clipboard plus Ctrl+V (Ctrl+Shift+V in terminals, where multi-line pastes are refused) and restores the previous text clipboard. The same change without the menu:

```bash
~/.config/omarchy/plugins/dstahl.mouthtype/control.py set-config delivery paste
```

Choose a dictation key under **Change Dictation Shortcut…**: press-to-toggle or hold-to-talk on any letter, digit, F-key, named key or a lone modifier such as Right Ctrl. Without the menu, for example hold-to-talk on F8:

```bash
~/.config/omarchy/plugins/dstahl.mouthtype/control.py set-shortcut hold F8
```

A key that Hyprland already binds is refused, and the previous binding file is backed up and restored if Hyprland rejects the change.

Check: `~/.config/omarchy/plugins/dstahl.mouthtype/control.py state` shows `"delivery_mode": "paste"` under `config`, and `"shortcut"` is `toggle` or `hold`.

## 7. First take

Press the shortcut, say a sentence, press it again (or release the hold key). The pill at the bottom of the focused display shows the level while recording, a wave while transcribing, then a short note. The text is pasted into the active window when paste delivery is on; it is always also saved and readable with `mouthtype-linux list` and `mouthtype-linux recover ID`.

Check: `mouthtype-linux list` shows one take with `"transcript": true`.

## 8. Optional: Fast and Thorough AI cleanup

From the menu, **Cleanup** → **Prepare Fast cleanup…** (about 480 MB download plus a short CPU build of the pinned llama.cpp server) or **Prepare Thorough cleanup…** (about 2.5 GB). Without the menu:

```bash
python3 tools/linux-desktop/setup_cleanup.py --destination "$HOME/.local/share/mouthtype/cleanup-candidate" --level fast
```

Add `--level thorough` for both. Then choose Fast or Thorough under **Cleanup**; the service restarts with the model loaded. Fast (S1-mini) answers in well under a second for ordinary takes on a modern CPU; Thorough (Qwen3 4B) takes several seconds and needs about 5 GiB of memory. When a model is too slow or changes the meaning, the Basic text is kept.

Check: `mouthtype-linux --config "$HOME/.local/share/mouthtype/speech-candidate/linux.json" doctor` reports `cleanup_model` as OK, and `mouthtype-linux status` shows `"cleanup": {"level": "fast", ...}` with a model state of `ready`.

## 9. Optional: transcribe an audio file

**Transcribe Audio File…** in the menu opens the desktop file chooser for one WAV, AIFF or M4A file of up to 10 minutes and 512 MB, then shows the raw result with Copy and Save Text. Without the menu: `mouthtype-linux import /path/to/file.m4a`, then `mouthtype-linux import-status` and `mouthtype-linux import-result`.

## Removing

```bash
systemctl --user disable --now mouthtype-linux.service
rm -rf ~/.config/omarchy/plugins/dstahl.mouthtype ~/.local/lib/mouthtype-linux ~/.local/bin/mouthtype-linux
rm -f ~/.config/systemd/user/mouthtype-linux.service ~/.config/mouthtype/omarchy-plugin.json
systemctl --user daemon-reload
```

Then remove the `dstahl.mouthtype` entry from `~/.config/omarchy/shell.json` and the marked Mouthtype block from `~/.config/hypr/bindings.lua`, and restart the shell with `omarchy-restart-shell`. Models and recordings live under `~/.local/share/mouthtype` and `~/.local/state/mouthtype`; delete them only if you no longer want them.

## Limits worth knowing

Linux cannot detect password fields, so paste and type delivery go wherever the cursor is. Insertion is not verified; the saved text is always available. Lone modifier keys fire inside their own shortcuts (Right Ctrl as hold-to-talk also triggers during Ctrl+C with that key). The Hi-Fi pill is drawn at Hyprland scale 1; other scales were not checked. Everything runs locally; nothing is uploaded.
