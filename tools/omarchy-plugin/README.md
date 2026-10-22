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

Update an existing install with `--update`.

`--uninstall` removes the plugin, its bar entry, the login service, the marked shortcut block and the plugin settings file (backing up each file it edits); models and recordings stay unless `--purge` is added. `--shortcut toggle|hold` also binds the default dictation key. Install also binds Super+Shift+T to Transform Selection in a second marked block (`--no-transform-shortcut` skips it); like the dictation key it refuses a key Hyprland already uses, reloads Hyprland and reverts if the file is rejected, and `--uninstall` removes it. `control.py set-transform-shortcut on|off [KEYS]` does the same by hand. Where `omarchy-plugin-add` and `git` exist, a fresh install goes through Omarchy's own `omarchy plugin add --yes --enable` (it validates the manifest and registers the plugin in the running shell) using a one-commit repository made from these files, because that command takes a git repository whose root is the plugin and ours is a subfolder; `--copy` forces the plain file copy, which is also the fallback when the command fails. Omarchy has no system-wide plugin directory (it scans only its own bundled plugins and `~/.config/omarchy/plugins`), so a packaged copy under `/usr/share` is only a source. Update with `--update`, not `omarchy plugin update`, whose git remote here is a throwaway directory. `tools/linux-desktop/setup.py` runs speech preparation and this installer together.

When the login service exists, the menu's start and Quit go through `systemctl --user` so the restart policy does not undo a Quit.

The complete ordered procedure with checks, written for people and coding agents, is at https://mouthtype.app/linux/agent-install.md. Keep backups outside `~/.config/omarchy/plugins`, because the shell loads every folder there. The Hi-Fi pill artwork under `assets/hifi` is copied from the Mac app's pill resources.

Settings are stored in `~/.local/share/mouthtype/speech-candidate/linux.json`, `~/.config/mouthtype/omarchy-plugin.json`, a managed user service, and a marked block in the Hyprland bindings file.

## Control modules and versions

`control.py` loads every sibling `control_<name>.py` that defines `COMMANDS = {"verb": function}` and runs the verb as `control.py verb [args...]`. The function takes the remaining arguments as strings and returns a JSON-serialisable dict, or raises `RuntimeError`, `OSError` or `ValueError` with a message the panel can show. A verb cannot replace a built-in action or one from an earlier module (alphabetical), and a module that fails to import is noted in `omarchy-control.log` and skipped.

`install.py` writes `version.json` (`plugin` from `manifest.json`, `app` from `packaging/Version.plist` when installing from a checkout) next to the installed files. `control.py state` reports both under `versions`; they are `null` when unknown.

## Panel layout and pages

The panel is one window: a sidebar (Home, Stats, Dictionary, Transforms, Style, Appearance, Settings) and a page. Settings opens a modal with General, Linux, Health and, while its footer switch is on, Advanced. `Panel.qml` owns the state and the `control.py` processes; `MouthtypeShell.qml` lays out the window; each page is a file in `pages/`. `shell-render/render_shell.sh <dir>` renders every page and the modal, light and dark, offscreen on the NAS testbed and runs `shell-render/tst_shell.qml` and `shell-render/tst_library.qml`.

Stats is built: `pages/StatsPage.qml` with its parts in `pages/stats/`, fed by the `stats` verb. Style is built too, see the Style page section below. Dictionary and Transforms are built: the helpers, sheets and fixtures are in `pages/library/`, the fixtures are real `control_library.py` output, and the Import CSV sheet takes a file path because the plugin's file chooser only opens audio files. A slice that builds a page replaces `pages/<Name>Page.qml` and keeps this contract, which is also written at the top of `MouthtypeShell.qml`:

- The root is an `Item` with an `implicitHeight`. The shell sets its width and scrolls it.
- `property var backend` is set by the shell to `{ state, results, busy, error, dark }`. `state` is the last `control.py state` reply, `results[verb]` is the last parsed reply of each verb the page requested, `busy` is true while a request runs, and `error` is the last request's message or `""`. The shell assigns a new object on every change.
- `property bool active` is true while the page is shown and no modal is open.
- `signal request(string command, var args)` asks the shell to run `control.py <command> <args...>`. Requests run one at a time, in order, and any verb `control.py` accepts works, including those from a `control_<name>.py` module.

`control_library.py` adds the Dictionary and Transforms verbs. They print the same JSON as the `mouthtype-linux spellings` and `phrases` commands documented in `tools/linux-desktop/README.md`: `spellings-list`, `spellings-add HEARD WRITTEN`, `spellings-edit HEARD NEW_HEARD NEW_WRITTEN [EXPECT_WRITTEN]`, `spellings-remove HEARD [EXPECT_WRITTEN]`, `spellings-import-preview FILE`, `spellings-import FILE [DIGEST] [CSV_DIGEST]`, `phrases-list`, `phrases-add TRIGGER EXPANSION`, `phrases-edit TRIGGER NEW_TRIGGER NEW_EXPANSION [EXPECT_EXPANSION]` and `phrases-remove TRIGGER [EXPECT_EXPANSION]`. An optional argument may be passed as an empty string to leave it unset.

## Transform Selection panel

`TransformWindow.qml` is the floating Transform Selection card, loaded by `Service.qml` once the file exists. The card, its chips and its text views live in `transform/`; `transform/TransformModel.js` holds every decision as plain functions so the card is a view. `transform-render/render_transform.sh <dir>` renders eight scenes in light and dark (normal, AI ready, AI busy, refused, model missing, over the 2,000 character highlight cap, accepted, capture error) on the NAS testbed and runs `transform-render/tst_transform.qml`. `transform-render/make_fixtures.py` rewrites `transform/fixtures/*.json` from the real backend.

Open it with a key bound to `control.py transform-open`. That verb captures the selection (primary selection, clipboard as fallback) in its own process, before focus moves, and writes the reply to `$XDG_RUNTIME_DIR/mouthtype/panel-transform.json`. The window polls that file every 400 ms and shows the card for a reply less than 30 seconds old. Plugin install binds Super+Shift+T to it for you (see above). To bind a different key by hand (choose an unused one; this is only an example):

```
hl.bind("SUPER + SHIFT + T", hl.dsp.exec_cmd("~/.config/omarchy/plugins/dstahl.mouthtype/control.py transform-open"))
```

or, on Hyprland 0.54 and older, `bind = SUPER SHIFT, T, exec, ~/.config/omarchy/plugins/dstahl.mouthtype/control.py transform-open`.

The layer surface asks for keyboard focus on demand only, so it does not take focus when it appears and gets it when you click into the result box. Before Accept, the window runs `control.py transform-focus ADDRESS`, which is `hyprctl dispatch focuswindow address:ADDRESS` on the window the selection came from, because `transform accept` refuses unless that window is focused. Cancel while an AI transform runs sends SIGTERM to the running verb, which `control_transform.py` passes to the CLI so the model worker stops.

## Style page

`pages/StylePage.qml` has five tabs: Personal messages, Work messages, Email, Other and Cleanup. Each context tab shows three tone cards (the sample lines and the highlighted characters come from the `samples` in `style-state`, not from the page), the apps that count as that context tagged BUILT IN or ADDED BY YOU with a tone popup and a cleanup popup each, a row that adds an app by window class (find it with `hyprctl clients`), and a "Cleanup here" popup. A context with no tone yet shows `suggested_tone` as a quiet hint. Other holds the default tone, a cleanup level and the per-app rules that no list claims. Linux has no website rows: Wayland does not tell Mouthtype which site is open.

The Cleanup tab is where the global cleanup level (Off, Basic, Fast, Thorough) is chosen, through `set-config cleanup`. Settings, Health keeps the model status and the Prepare buttons and points here for the level. Edits are written to `linux.json` and the dictation service reloads them on the next take.

Every edit verb replies with the full Style state, so the page treats the newest reply as current and does not re-read after an edit. Per-app tone and cleanup popups write a per-app rule with `style-rule` for each window class the app ships under. `pages/style/fixtures/gen_fixtures.py` regenerates the fixtures the render scenes use from the real `styles.describe`; `test_style_page.py` fails when they are stale.

## Limits

> [!NOTE]
> The Linux client does not currently provide live word previews, secure-field detection or insertion verification. The plugin reads `mouthtype-linux capabilities` and shows only supported controls; **About Mouthtype** explains the gaps.
