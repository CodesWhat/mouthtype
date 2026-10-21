# Mouthtype for Omarchy

This bar widget controls the locally installed Mouthtype Linux client. It uses the Mac application's menu structure and status glyphs where the Linux client has matching functionality.

## What it does

Open the Mouthtype glyph on the right side of the Omarchy bar. The menu can:

- Start, stop, or cancel dictation.
- Show, copy and forget recent transcripts.
- Manage **Dictation History**: count against the limit, forget by age or keep the newest, the limit itself, and how long completed audio is kept.
- Retry saved audio.
- Transcribe one audio file.
- Configure Basic cleanup, recording length, notifications, delivery, sounds, login startup, and dictation shortcuts.

## Transcribe Audio File

**Transcribe Audio File…** opens the desktop file chooser for one WAV, AIFF or M4A file of up to 10 minutes and 512 MB. It then shows preparation, transcription and cancellation states with the full raw result.

- **Copy** puts the result on the clipboard.
- **Save Text…** writes a UTF-8 text file through the desktop save dialog.
- Neither runs automatically, cleanup and saved spellings are not applied, and the result is kept out of Recent Dictations.
- The client refuses to save the transcript over the original audio file.
- The menu shows this item only when the installed client reports the capability, and the client needs the distro `ffmpeg` package.

## Floating Pill

**Floating Pill** shows a Mac-style pill at the bottom of the focused display while you dictate: the Classic capsule or the Hi-Fi unit (standard or 2×). It has a live level meter, cancel and stop, a wave while transcribing and a short note when the take settles. It is a click-through overlay that never takes keyboard focus; only its two buttons accept clicks.

**Text Font** chooses the font for Mouthtype's own menu, transcript cards and the Classic pill (Default, Sans, Serif, Mono or a custom family) with optional overrides per role and a preview. The app you dictate into still chooses the font for inserted text.

## Delivery

Delivery defaults to saving transcripts locally. **Paste into the active window** puts the transcript on the clipboard and sends Ctrl+V to the window that was active when you started speaking (Ctrl+Shift+V in terminals, where multi-line pastes are refused), then restores your previous text clipboard.

To type into another app, open **Paste Options**, enter that app's exact Hyprland window class, and enable guarded typing. The client accepts single-line text for typing.

> [!WARNING]
> Linux cannot identify password fields, so use guarded typing only with an app you trust.

## Change Dictation Shortcut

**Change Dictation Shortcut…** offers press-to-toggle and hold-to-talk on a key of your choice. Press the combination in the menu or type it (letters, digits, F-keys, named keys such as Insert, with optional SUPER, ALT, CTRL or SHIFT).

| Mode | Default |
| --- | --- |
| Press to toggle | Super+Alt+M |
| Hold to talk | F10 |

The plugin:

1. Refuses a key Hyprland already binds.
2. Backs up `~/.config/hypr/bindings.lua`.
3. Writes one marked block.
4. Reloads Hyprland.
5. Reverts if the configuration is rejected.

Existing Voxtype shortcuts are left in place.

## Cleanup

**Cleanup** offers Off, Basic, Fast (S1-mini by Superwhisper) and Thorough (Qwen3 4B Instruct 2507), the last two as local llama.cpp models on the CPU. Fast and Thorough can be chosen only after **Prepare … cleanup…** has downloaded and verified the pinned model and built the pinned server. The page shows preparation progress, the model state and the last take's outcome. When a model is too slow or changes the meaning, the Basic text is kept.

## Install

The installed plugin is at `~/.config/omarchy/plugins/dstahl.mouthtype`. Its source lives in this directory of the Mouthtype repository (`tools/omarchy-plugin`). Install it with `python3 tools/omarchy-plugin/install.py`, which:

1. Copies these files to the plugin folder.
2. Adds the widget to the bar layout in `~/.config/omarchy/shell.json` after backing it up.
3. Enables the `mouthtype-linux` systemd user service so dictation starts with every graphical session, after the Wayland session is up. Skip this with `--no-autostart`; **Launch at Login** in the menu toggles it later.
4. Starts the service.
5. Restarts the Omarchy shell (`--no-restart-shell` to skip).

Update an existing install with `--update`. When the login service exists, the menu's start and Quit go through `systemctl --user` so the restart policy does not undo a Quit.

The complete ordered procedure with checks, written for people and coding agents, is at https://mouthtype.app/linux/agent-install.md. Keep backups outside `~/.config/omarchy/plugins`, because the shell loads every folder there. The Hi-Fi pill artwork under `assets/hifi` is copied from the Mac app's pill resources.

Settings are stored in `~/.local/share/mouthtype/speech-candidate/linux.json`, `~/.config/mouthtype/omarchy-plugin.json`, a managed user service, and a marked block in the Hyprland bindings file.

## Limits

> [!NOTE]
> The Linux client does not currently provide live word previews, secure-field detection or insertion verification. The plugin reads `mouthtype-linux capabilities` and shows only supported controls; **About Mouthtype** explains the gaps.
