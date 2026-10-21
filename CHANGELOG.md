# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

[`packaging/ReleaseNotes.txt`](packaging/ReleaseNotes.txt) is the cumulative text shown inside the app. This file is the per-release history. Mouthtype supports Apple Silicon Macs on macOS 26 or later. The Linux client is experimental source only and isn't a supported release.

## [Unreleased]

Work on `dev/v0.5.0`, merged since 0.4.0.

### Added

- Spoken slash commands in coding apps. Saying "slash research" types `/research`, and "dash", "hyphen" and "underscore" join more words ("slash code dash review" is `/code-review`). It only runs in terminals, editors, JetBrains, and the Claude, ChatGPT, Codex and Orca apps (plus claude.ai and chatgpt.com in a supported browser). There's an Advanced toggle, on by default.
- Show in Dock in Settings > Mac: Never, While a window is open (the default) or Always. The menu bar icon stays in every mode.
- A docs site at docs.mouthtype.app.
- Real app icons in the Style lists. Built-in apps that aren't installed are hidden from the Counts as lists.

### Changed

- Launch is faster. The status item appears before anything draws with a bundled font, bundled fonts register off the launch path, the Settings window is built on first present, and unchanged phrase files aren't re-read.
- Dictation is faster. Voice activity detection and Parakeet transcription run concurrently, and the editor-hint bias build starts at key-down.
- Thorough cleanup is faster. The unchanging part of the cleanup prompt is cached between takes, so each take only processes what follows it. In one benchmark the median per-case time went from 823 ms to 435 ms.
- The cleanup model unloads after 10 minutes without use and reloads when you start your next take.
- Per-take dictionary setup is cached on the rule list.
- The Transform Selection panel no longer shows an eyebrow header.
- The website hero puts the mouth first in the menu bar.

### Fixed

- Fn remap: repairs are bounded and re-verified against the live HID mapping, and the crash guard restores your own Fn mapping.
- SIGTERM and SIGINT go through the normal quit path, drafts are kept on a signal quit and aren't restored at launch, and open-URL events wait for launch to finish.
- Paste is refused when the focused element belongs to another process, and the paste owner is judged by AX application instead of raw pid.
- An undone take is archived before waiting on the earlier job.
- Completed-audio listing ignores a stale stamped expiry.
- Cleanup keeps dictated quotes and a dictated preamble, strips model framing from the output, applies joined saved spellings when the model result isn't used, and no longer reads "no one" as a self-correction.
- Copies made from the card, Recent Takes and cleanup are marked concealed on the clipboard.
- Editor hints turn off git lazy fetch and fsmonitor when listing files.
- The corrections similarity check caps word length.

## [0.4.0] - 2026-10-21

### Added

- Transform Selection from the menu bar: Clean up, Fix grammar, Make shorter, More formal and More casual. A preview panel shows removed words struck through and an editable result with Accept, Copy result, Retry and Cancel. Accept replaces text only if the app, field and selection are unchanged.
- A Transforms page listing your phrases (text, lines, clipboard or date) and the five selection transforms with model status.
- Transcribe Audio File in its own window, with name, length, size, raw transcript, word count, Copy and Save Text.
- Automation through `mouthtype://` URLs and a `mouthtype` command-line script: start, stop, toggle, cancel, copy-last, paste-last and open a page. Dictation commands stay off until you turn on the automation switch.
- Editor hints: with Boost my saved words on, up to 40 code names from VS Code, Cursor, Xcode and Terminal can boost one take. Off by default, nothing is kept after the take.
- History limit and audio retention in the experimental Linux client source.

### Changed

- One redesigned window with a new palette and SF Symbols sidebar: Home, Stats, Dictionary, Transforms, Style, Appearance and a Settings modal. Saved spellings and Phrases are pages in that window. Leaving with an unsaved draft still asks first.
- Quiet other audio is on by default. If you turned it off before, it stays off.
- The menu bar menu is plain text.
- Saved phrases and Very Casual are no longer in the Transform Selection menu.

### Fixed

- A failed audio import keeps the previous transcript.

## [0.3.0] - 2026-10-20

### Added

- Home page with your last 50 takes, each with Copy and Recover.
- Stats page with words today, this week and all time, a 14-day chart, speed, streaks, records and time saved compared with typing at 40 WPM. Takes from secure fields are never counted.
- Saved spellings suggest spellings from your recent takes, with examples, Add, Remove, Dismiss and Undo. They also flag heard forms that rewrite everyday words.

### Changed

- With Keyboard navigation on, Settings scrolls to follow Tab and Shift-Tab.

## [0.2.0] - 2026-10-19

### Added

- Transform selected text: Fix grammar, Make shorter, Make more formal and Make more casual on the Thorough model, with an editable preview.
- Boost my saved words while recognising, off by default. It downloads an English speech model of about 100 MB on first use, and dictation never waits for it.
- App and website rules can set a cleanup level as well as a tone.

### Changed

- Formal tone removes or softens swearing at Basic, Fast and Thorough.
- Saved spellings warn when a heard form is an everyday word. Those aren't used as boost hints.
- Appearance preview offers Light and Dark, and Desktop is gone. Glass no longer judges itself against Apple's placeholder picture for live wallpapers.

### Fixed

- With Keyboard navigation on, Tab reaches the page controls and Shift-Tab steps back. Sidebar rows show focus.

## [0.1.0] - 2026-10-19

First stable release for Apple Silicon Macs on macOS 26 or later. Hold Fn, speak, release, and clean text is pasted where you're typing. Recognition and cleanup run on your Mac.

### Added

- Recovery of an interrupted take on the next launch.

### Changed

- The docs say plainly that Tab doesn't reach Settings controls yet. This is fixed in 0.2.0.

## Pre-releases

0.1.0 was preceded by `v0.1.0-alpha.1` through `v0.1.0-alpha.9`, `v0.1.0-beta.1` and `v0.1.0-rc.1` through `v0.1.0-rc.4`. Each has a tag on the [releases page](https://github.com/CodesWhat/mouthtype/tags). Their notes are folded into the 0.1.0 entry in [`packaging/ReleaseNotes.txt`](packaging/ReleaseNotes.txt).

[Unreleased]: https://github.com/CodesWhat/mouthtype/compare/v0.4.0...dev/v0.5.0
[0.4.0]: https://github.com/CodesWhat/mouthtype/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/CodesWhat/mouthtype/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/CodesWhat/mouthtype/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/CodesWhat/mouthtype/releases/tag/v0.1.0
