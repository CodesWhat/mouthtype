# Automation

Mouthtype has a small local automation surface: a `mouthtype://` URL scheme and a thin `mouthtype` command that wraps it. It's for Shortcuts, Raycast, scripts and keyboard launchers on your own Mac. There's no network listener, no accounts and no MCP server.

The scheme comes from `CFBundleURLTypes` in the built app. An app bundle built before this change has to be rebuilt and launched once so LaunchServices registers `mouthtype://`.

## Turn it on

Verbs that record, copy or insert are off until you opt in, because any web page can open a `mouthtype://` link. Opening a page works without it. If you have an unsaved spelling or phrase, the window asks before leaving that page.

```sh
defaults write com.codeswhat.mouthtype automationEnabled -bool true
```

Turn it off with `defaults delete com.codeswhat.mouthtype automationEnabled`. A refused URL does nothing, shows "Automation is off" in the pill and is logged (Console, subsystem `com.codeswhat.mouthtype`, category `app`).

## URLs

| URL | What it does | Same as |
| --- | --- | --- |
| `mouthtype://start` | Starts a hands-free recording. Ignored if one is running. | The toggle shortcut, first press |
| `mouthtype://stop` | Stops a hands-free recording and delivers it. | Stop Dictation in the menu |
| `mouthtype://toggle` | Stops a hands-free recording, or starts one when idle. | The toggle shortcut |
| `mouthtype://cancel` | Cancels a hands-free recording. | Cancel Dictation in the menu |
| `mouthtype://copy-last` | Copies the last delivered text. | Copy Last Take in the menu |
| `mouthtype://paste-last` | Pastes the last delivered text. | Paste Last Take in the menu |
| `mouthtype://open?page=<page>` | Shows that page in the Mouthtype window: `home`, `stats`, `records`, `spellings`, `phrases`, `transcribe`, `general`, `writing`, `appearance` or `diagnostics`. The old names keep working and go to their new homes: `records` is Stats, `spellings` is Dictionary, `phrases` is Transforms, `transcribe` opens or focuses the Transcribe Audio File window, which is its own window and leaves the Mouthtype window where it is, `writing` is Style, `general` opens the Settings modal on General and `diagnostics` opens it on Health. `settings` or no page shows the window on whatever page it's on. | Settings in the menu |

Every verb goes through the same code as the menu and hotkeys, so the busy, permission, engine-readiness and secure-field checks still apply. Pasting still refuses secure fields and changed destinations. `stop` and `cancel` only act on a hands-free recording, same as the menu. While you're holding the dictation key, `start` and `toggle` do nothing, and two starts fired together begin one recording, and the second shows "Already starting" in the pill and is logged.

Anything else is ignored and logged: unknown verbs, unknown pages, extra path segments, other schemes. Parameters other than `page` are dropped. URLs can't return a value, so there's no `status` yet.

## Command line

`scripts/mouthtype` is a shell wrapper around `open -g mouthtype://...`. A SwiftPM executable would add a build target and a signing step to forward a string to LaunchServices, and `open` already launches the app if it isn't running.

```sh
ln -s "$PWD/scripts/mouthtype" /usr/local/bin/mouthtype
mouthtype toggle
mouthtype paste-last
mouthtype open appearance
```

`mouthtype --help` prints the usage and exits 0. Any bad verb, bad page or extra argument prints the usage to stderr and exits 64 without opening anything.

URL commands run in the order they arrive, so `start` followed by `stop` stops the recording the start is still bringing up. A command waits at most 10 seconds for the one before it, so a start that never returns can't hold up a later `stop` or `cancel` forever. A `stop` or `cancel` that stops waiting this way is remembered by the start and applied the moment the recording comes up: `stop` ends and transcribes it, `cancel` discards it, and it is never left locked on. A recording started this way stops with the dictation key and cancels with Esc, like one started from the keyboard.

## Shortcuts

Add an "Open URLs" action and set it to `mouthtype://toggle`. Use one shortcut per verb and give each a keyboard shortcut or put it in the menu bar.

## Raycast

A script command, saved as `mouthtype-toggle.sh` in your script directory:

```sh
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Toggle Mouthtype Dictation
# @raycast.mode silent
# @raycast.packageName Mouthtype

open -g "mouthtype://toggle"
```

Or use Raycast's "Open URL" quicklink with `mouthtype://paste-last`.

## Privacy

Nothing leaves the Mac. The URL carries a verb and at most a page name, never text or audio. Recordings started this way show the normal pill and play the normal cues.
