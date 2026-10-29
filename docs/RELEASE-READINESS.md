# Mac 0.9.1 release readiness

What each stable release added:

- Stable 0.9.1 (build 24) fixes the first Press Return after inserting in a listed Electron app like the Claude desktop app, which now waits briefly for the app's accessibility to come up, and updates Sparkle to 2.10.1, which fixes an update installing before the app quit when Mouthtype sits in an NFC Unicode path.
- Stable 0.9.0 (build 23) makes Press Return after inserting work in terminals you add (Terminal, iTerm2, Ghostty, WezTerm, Warp, kitty, Alacritty, Hyper and Orca), where Mouthtype can't confirm a paste and presses Return a moment after it without checking, and in Electron apps like the Claude desktop app with context names off, by turning on their accessibility when a recording starts. The guards stay: never in password fields or secure input, after a recovered take or Paste Last, or if you typed or clicked after the paste.
- Stable 0.8.0 (build 22) adds Press Return after inserting, an opt-in list in Settings > Advanced of apps where Mouthtype presses Return once after a confirmed paste (off by default, never in password fields or secure input, and never for recovered takes or Paste Last; Apple Terminal can't confirm a paste, so it never sends there, and other apps send only when Mouthtype can confirm the text landed), and a narrow Formal cleanup fix: a swear word used as a verb after he, she or I with a form of "be" and before a word for people such as women, men or guys now becomes "sleeping with" instead of being dropped.
- Stable 0.7.0 (build 21) added Japanese, Hindi and Tamil dictation in Beta through the multilingual Whisper Turbo model (a separate 1.6 GB download, no live words while Whisper Turbo is in use), selected-text cleanup that applies website, then app, then global tone and reads the selection off the main thread, fixes for punctuation near saved multiword terms, cleanup timeout fallbacks, dictionary rule usage with boundary apostrophes and the streak when the local date moves backward, a website typing speed test with a countdown, Swift tests on every pull request with an 80% line-coverage floor, and a fuzz target for the phrase matcher.
- Stable 0.6.0 (build 20) added dictation in 25 languages with Auto-detect, a mouse-button trigger, dictionary export and Wispr Flow and VoiceInk import, a Models page and name accuracy card in Setup, a silent-microphone warning with a Setup test take, cleanup instructions with presets and an Excited tone, website favicons in the Style lists, a Microphone settings page, repeatable release builds and a Homebrew cask.
- Stable 0.5.0 (build 19) added faster launch, dictation and Thorough cleanup, spoken slash commands in coding apps, Show in Dock, the docs site, Fn remap and quit-path hardening, cleanup fixes, real app icons in the Style lists, and a notarized DMG as the first-install download.
- Stable 0.4.0 (build 18) added the one-window redesign, Transform Selection from the menu bar, the Transforms page, a separate Transcribe Audio File window, the mouthtype:// URL scheme and command-line script behind an automation switch, optional editor hints for the saved-word boost, and Quiet other audio on by default.
- Stable 0.3.0 (build 17) added the Home page with recent takes and Recover, local stats and records, saved-spelling suggestions from recent takes, and Settings scrolling that follows Tab.
- Stable 0.2.0 (build 16) added selected-text transforms, optional saved-word boosting during recognition, cleanup levels in app and website rules, the Formal swearing change, Settings keyboard access and the Appearance preview change.
- Stable 0.1.0 (build 15) was cut from the rc.4 tree plus the quit-recovery fix and a docs correction.

Not verified on a device for stable 0.9.1:

- Fresh install on a Mac that has never run Mouthtype.
- VoiceOver.
- Bluetooth and USB microphones.
- Real speech in languages other than English. Those paths were checked with fixtures and synthetic voices only.
- Press Return after inserting, which was checked with unit tests and offscreen renders and never in a live app.
- The Japanese, Hindi and Tamil Beta paths and their 1.6 GB model download, which were checked with synthetic speech and renders only.
- The new Setup, Microphone and Style screens, which were checked by renders and no one has used them on a Mac yet.

Phase3 froze the beta.1 feature set. The rc.1/build11 candidate was followed by rc.2/build12, which adds the visual refresh and default-on update checks, rc.3/build13, which fixes the rc.2 review findings, and rc.4/build14, which fixes the rc.3 review findings, before stable0.1.0. The new interface has automated and offscreen rendering coverage only; it adds no physical acceptance. The earlier candidates were not a declaration that every stable gate had passed, and this stable release doesn't claim the unverified items above. The repository remains private; published app/source/feed assets are verified independently.

## Evidence and remaining gates

| Area | Evidence | Limit or remaining gate |
| --- | --- | --- |
| Audio quieting | Released source reproduced its own delayed mute callback; actual production adapter passed ten restoration cycles after the fix and preserved observed user mute/volume changes. | Built-in output only. HAL provides state notifications, not the author of a change; coalesced unobservable transitions cannot establish intent. |
| Clipboard ownership | Real unique native pasteboards preserve rich/multiple items and a newer copy. Existing delayed-read, cancellation, ordered-delivery and shutdown regression tests pass. | No general clipboard or keys are used by these tests. They do not prove cross-app clipboard restoration or explain the earlier additional Chrome take. |
| Saved data | Read-only SQLite backup, production-store reopen on a disposable copy, unchanged schema/counts/typed-value digests and a committed-WAL regression. Existing v1-to-v2 migration coverage passes. | No live database edits or personal-text fixtures. Fresh-machine data transfer is separate. |
| Setup and permissions | Authorized/denied/missing-device state logic and normal/minimum offscreen rendering pass. Existing developer-machine microphone and Accessibility grants are retained. | Fresh user/machine permission prompts are unverified. Existing grants and caches do not prove first install. |
| Updater | Signed feed/archive verification, tamper rejection, packaging checks and idle/busy/termination logic pass. A disposable external-host Sparkle check app was prepared. | Native control could not attach to that check window, so no update was initiated. An rc.2 to rc.3 Sparkle update was later observed installing and relaunching on one Mac. Data and permissions survived, no prompt appeared, and quit/relaunch passed. Other macOS versions and fresh installs are unverified. |
| Settings access | Persisted settings, action routing, keyboard shortcuts in menus and offscreen views have automated coverage. | Settings Tab and Shift-Tab, focus rings, arrow navigation and Tab scrolling passed on device on 2026-10-19 and 2026-10-20. Recover after quit passed on device on 0.1.0 (2026-10-19), and quiet-audio restore passed once Quiet other audio was turned on. The maintainer deferred VoiceOver acceptance; it is not a release gate. Rendering and identifiers do not establish native accessibility behavior. |
| Supported apps/devices | Earlier beta.1 TextEdit/Chrome ordered takes and live words, plus the current built-in output checks. | Broader browser/terminal/Electron, Bluetooth, removal/reconnect, sleep/clamshell and imported-file recognition remain unverified. |

The maintainer explicitly ended manual QA requests and deferred VoiceOver testing until user feedback warrants it. VoiceOver coverage is unverified, not passed, and does not block Phase3 or stable release. Do not turn tool limitations into another manual script. Keep unavailable cases unverified. Stable requires supported installation/update/data-recovery paths to pass and any release-blocking regression to be resolved. Do not rename missing evidence as a pass or publish stable solely to complete a goal.

## Repeating the native component checks

Run the normal Mac/Core suite with `swift test`. Real output tests are opt-in: `MOUTHTYPE_NATIVE_AUDIO_TESTS=1 swift test --filter CoreAudioQuietOutputTests`. They require an initially unmuted, supported output and briefly change its owned mute/volume state before restoring it. Do not run them concurrently with a person changing audio or another output check.

NativePasteboardTests run against separate unique pasteboards and emit no keyboard events. The optional SavedDataCompatibilityTests snapshot case uses MOUTHTYPE_COMPAT_DATABASE to identify an existing consistent snapshot or an active WAL database. It opens that source read-only and uses SQLite backup into its disposable copy. Finalize an offline snapshot to a standalone journal before read-only access; do not checkpoint or change the user's live database for a test. Logs contain schema metadata/counts/digests rather than personal text. The synthetic WAL case runs without that setting.

## Release procedure

Follow [RELEASING.md](RELEASING.md). Update packaging, SECURITY.md, website version/build labels and redirects together. Require actual included-capacity review of changed blobs, relevant checks, normal development-to-main sync and tree equality. Sign the exact main tag, notarize/staple, preserve immutable older downloads and verify actual public ZIP/source/feed/site bytes. An RC may document open gates; stable must not claim those gates passed without evidence.
