# Automation

Mouthtype has a small local automation surface: a `mouthtype://` URL scheme and a thin `mouthtype` command that wraps it. Use it from Shortcuts, Raycast, scripts and keyboard launchers on your own Mac. There's no network listener, no account and no MCP server.

## Turn on the automation switch

> [!WARNING]
> Commands that record, copy or insert are off until you opt in, because any web page can open a `mouthtype://` link. Opening a page of the window works without the switch.

```sh
defaults write com.codeswhat.mouthtype automationEnabled -bool true
```

Turn it back off with `defaults delete com.codeswhat.mouthtype automationEnabled`. A refused URL does nothing and shows "Automation is off" in the pill.

## URLs

| URL | What it does |
| --- | --- |
| `mouthtype://start` | Starts a hands-free recording |
| `mouthtype://stop` | Stops a hands-free recording and delivers it |
| `mouthtype://toggle` | Stops a hands-free recording, or starts one when idle |
| `mouthtype://cancel` | Cancels a hands-free recording |
| `mouthtype://copy-last` | Copies the last delivered text |
| `mouthtype://paste-last` | Pastes the last delivered text |
| `mouthtype://open?page=<page>` | Shows a page in the Mouthtype window |

Every command goes through the same code as the menu and the hotkeys, so busy, permission, model-readiness and secure-field checks still apply. Anything unrecognized is ignored. URLs can't return a value, so there's no status command.

## The mouthtype command

`scripts/mouthtype` is a shell wrapper around `open -g mouthtype://...`. Link it somewhere on your path from a checkout or the source archive.

```sh
ln -s "$PWD/scripts/mouthtype" /usr/local/bin/mouthtype
mouthtype toggle
mouthtype paste-last
mouthtype open appearance
```

`mouthtype --help` prints usage. A bad verb, a bad page or an extra argument prints usage to stderr and exits 64 without opening anything.

## Shortcuts and Raycast

### Shortcuts

1. Add an "Open URLs" action set to `mouthtype://toggle`.
2. Make one shortcut per command.
3. Give each a keyboard shortcut or put it in the menu bar.

### Raycast

Save a script command like this, or use an "Open URL" quicklink with `mouthtype://paste-last`.

```sh
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Toggle Mouthtype Dictation
# @raycast.mode silent
# @raycast.packageName Mouthtype

open -g "mouthtype://toggle"
```

## Privacy

Nothing leaves the Mac. A URL carries a command and at most a page name, never text or audio. A recording started this way shows the normal pill and plays the normal cues.

## Full reference

Page names, ordering rules for back-to-back commands and the edge cases are in the [URL scheme and command reference](../AUTOMATION.md).
