# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

[`packaging/ReleaseNotes.txt`](packaging/ReleaseNotes.txt) is the cumulative text shown inside the app. This file is the per-release history. Mouthtype supports Apple Silicon Macs on macOS 26 or later. The Linux client is experimental source only and isn't a supported release.

## [Unreleased]

### Added

- Search retained raw and final transcripts and app names from Home, and play or stop a take's retained audio. Search finds older takes beyond the recent list; audio retention settings stay the same.

### Fixed

- Profanity cleanup preserves clear verbs after forms of “be”, including plural person subjects, split phrasal verbs and standalone frequency phrases, while retaining noun-predicate emphasis.
- Delivery card buttons in Classic, Glass, Matrix and Minimal now expose their labels and actions to accessibility tools, including Copy, Undo and Dismiss. Completed actions report their updated label and stay disabled.

## [0.9.1] - 2026-10-29

### Changed

- Updated Sparkle, the updater, from 2.10.0 to 2.10.1. It fixes an update that could install before the app quit when Mouthtype sits in a folder with an NFC Unicode name, and it improves update feed parsing and translations.

### Fixed

- The first dictation after opening a listed Electron app like the Claude desktop app can now press Return too, because Mouthtype waits briefly for the app's accessibility to come up.

## [0.9.0] - 2026-10-28

### Changed

- Press Return after inserting now works in terminals you add (Terminal, iTerm2, Ghostty, WezTerm, Warp, kitty, Alacritty, Hyper and Orca). They can't confirm a paste, so Mouthtype presses Return a moment after it without checking, never in password fields, after a recovered take, or if you typed or clicked after the paste. Settings shows a note on those rows.
- Press Return after inserting now works in Electron apps like the Claude desktop app even with context names off. Mouthtype turns on their accessibility when a recording starts in a listed app, so it can confirm the paste.

## [0.8.0] - 2026-10-27

### Added

- A Press Return after inserting list in Settings > Advanced. Add an app and Mouthtype presses Return once after a dictation lands there, only when the paste is confirmed in a text field you haven't touched since. It starts empty and never sends in password fields. Apple Terminal can't confirm a paste, so it never sends there. Other apps send only when Mouthtype can confirm the text landed; this hasn't been tried in live apps yet.

### Fixed

- Formal cleanup no longer drops a swear word used as a verb in one narrow case: after he, she or I with a form of "be" (including he's, she's and I'm) and before a word for people such as women, men or guys. It now becomes "sleeping with".

## [0.7.0] - 2026-10-25

### Added

- Dictation in Japanese, Hindi and Tamil, marked Beta in Settings. They run through the pinned multilingual Whisper Turbo model, a separate 1.6 GB download. Live words are unavailable whenever Whisper Turbo is used, including English takes in an Auto-detect set containing Japanese, Hindi or Tamil; the saved Live words preference returns when you switch back to Parakeet. Auto-detect candidate sets can include them. A recording, a Setup test take or a file import keeps its starting language if Settings changes mid-take. They were checked with synthetic speech only, never a fluent speaker or a physical microphone. See [`docs/LANGUAGES.md`](docs/LANGUAGES.md).
- A Start typing button and a 3-2-1 countdown prepared for screen-reader announcements on the website typing speed test, with focus and reset handling. Words per minute is timed from the first key.
- A libFuzzer target for the phrase matcher, run in the security workflow.

### Changed

- The website typing speed test is styled apart from the illustrative example card.
- CI runs the Swift tests on every pull request and holds an exact 80% Swift line-coverage floor.
- The Formal profanity model prewarms at startup only when Formal cleanup is enabled.
- Removed unused Cleanup, Paste and Pill Style menu code. Settings keyboard and window tests are more reliable, with added regression coverage for domain-field selection on keyboard re-entry.

### Fixed

- Selected-text cleanup applies the website tone first, then the app tone, then the global tone, and captures the selection off the main thread with a timeout.
- Punctuation across a boost alignment boundary no longer lands inside a saved multiword term.
- Cleanup timeout fallbacks (Basic, Fast and Thorough) still expand saved phrases.
- Dictionary rule usage honours apostrophes exactly, so a quoted rule is no longer counted as used by unquoted speech.
- The streak no longer resets when travel moves the local date backward.

## [0.6.0] - 2026-10-23

### Added

- Dictation in the 25 languages Parakeet v3 covers. Auto-detect is the default and picks each take's language from among English and the languages in your Mac's preferred list. You can also pick one language in Settings > General. Thorough cleanup covers English, German, Spanish, French, Italian, Portuguese, Dutch, Polish and Russian. Other languages get Basic cleanup. Fillers, spoken commands, slash commands, counted lists, self-correction, number formatting and swearing removal are English only. See [`docs/LANGUAGES.md`](docs/LANGUAGES.md).
- A Mouse button setting (None, Middle, Back or Forward) in Settings > General that dictates like the shortcut, in hold or toggle mode.
- Export the dictionary as CSV, and import Wispr Flow CSV and VoiceInk JSON dictionaries with a preview before anything is saved.
- A Models page in Set Up Mouthtype that puts every model download in one place, and a last card to get names right.
- A warning card when a take of a second or more heard nothing, naming the microphone that was recording, and an optional test take on Setup's last card. The test take never pastes and saves no transcript or audio.
- Each website in the Style lists shows its own favicon.
- A Microphone page in Settings, right after General, for the microphone picker and priority list.
- A Homebrew cask: `brew install --cask codeswhat/tap/mouthtype`.
- Instructions for Thorough cleanup. Write up to 500 characters on the Cleanup tab for every app, or on a single app or website row, such as "Keep it warm and short". They change tone and formatting only. The checks Thorough always runs still throw out any result that changes a name, number, negation or the language. Fast ignores them.
- A Start from menu beside each instructions box with three ready-made instructions: Slack, Keep my wording and Code comments. Choosing one fills the box for you to edit, and nothing is saved until you choose Save.
- An Excited tone beside Formal, Casual and Very casual. A short message ends with an exclamation mark, and Thorough uses them where you sound enthusiastic.

### Changed

- Release builds run in a repeatable mode with a fixed scratch path, and the manifest records it with the toolchain versions. See [`docs/REPEATABLE-BUILD.md`](docs/REPEATABLE-BUILD.md).
- Names on screen is now on by default. It still only acts when Boost saved words is on (off by default). If you turned it off before, it stays off. It also reads names from wider Accessibility text on screen.

## [0.5.0] - 2026-10-21

### Added

- Spoken slash commands in coding apps. Saying "slash research" types `/research`, and "dash", "hyphen" and "underscore" join more words ("slash code dash review" is `/code-review`). It only runs in terminals, editors, JetBrains, and the Claude, ChatGPT, Codex and Orca apps (plus claude.ai and chatgpt.com in a supported browser). There's an Advanced toggle, on by default.
- Show in Dock in Settings > Mac: Never, While a window is open (the default) or Always. The menu bar icon stays in every mode.
- A docs site at docs.mouthtype.app.
- A notarized DMG installer is now the first-install download. The ZIP stays as the update archive.
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
- SIGTERM and SIGINT go through the normal quit path, drafts saved on a signal quit are offered back on the recovery card at the next launch, and open-URL events wait for launch to finish.
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

[Unreleased]: https://github.com/CodesWhat/mouthtype/compare/v0.9.1...HEAD
[0.9.1]: https://github.com/CodesWhat/mouthtype/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/CodesWhat/mouthtype/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/CodesWhat/mouthtype/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/CodesWhat/mouthtype/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/CodesWhat/mouthtype/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/CodesWhat/mouthtype/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/CodesWhat/mouthtype/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/CodesWhat/mouthtype/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/CodesWhat/mouthtype/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/CodesWhat/mouthtype/releases/tag/v0.1.0
