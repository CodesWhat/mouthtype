# Mouthtype 0.8.0

Local dictation for Apple Silicon Macs running macOS 26 or later. Hold Fn, speak, release, and clean text is pasted where you're typing. Recognition and cleanup run on your Mac.

## Install

1. Download the DMG from https://mouthtype.app/download and open it.
2. Drag Mouthtype.app into Applications. Quit an older running Mouthtype before replacing it.
3. Open Mouthtype from Applications.
4. Follow Set Up Mouthtype, one card at a time. Allow Microphone access, then grant Accessibility in System Settings and return to the app. Each card advances when its prerequisite is ready. Reopen setup from Settings → Health → Set Up Mouthtype if you defer it.
5. Wait for the speech model to download and prepare. Downloads need internet access; transcription and cleanup run on your Mac. Basic cleanup works without a cleanup-model download. Optional Fast is roughly 1.4 GB; Thorough is roughly 5.2 GB.
6. Click a blank TextEdit document. Hold Fn, say a sentence, then release. Wait for text to appear. Dictate another sentence without clicking or typing between takes. Confirm one insertion per take and a space between them.

> [!NOTE]
> This distribution is Developer ID signed and notarized. If macOS rejects it, record the exact message; do not disable Gatekeeper.

The app’s Resources folder contains these notes and its license. Corresponding release source is available from https://mouthtype.app/source; the development repository is at https://github.com/CodesWhat/mouthtype.

## What changed in 0.8.0

Press Return after inserting, plus a Formal cleanup fix.

- Added: A Press Return after inserting list in Settings > Advanced. Add an app and Mouthtype presses Return once after a dictation lands there. It starts empty, so nothing is sent until you add an app. It sends only when it can confirm through accessibility that the text landed in the same field within about two seconds, you haven't typed or clicked since, and no new recording has started. It never sends in password fields or secure input, or for recovered or interrupted takes or Paste Last. Apple Terminal can't confirm a paste, so it never sends there. Other apps send only when Mouthtype can confirm the text landed; this hasn't been tried in live apps yet.
- Fixed: Formal cleanup no longer drops a swear word used as a verb in one narrow case: after he, she or I with a form of "be" (including he's, she's and I'm) and before a word for people such as women, men or guys. It now becomes "sleeping with".

> [!NOTE]
> Press Return after inserting was checked with unit tests and offscreen renders only, never in a live app. Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release. Japanese, Hindi and Tamil, their 1.6 GB model download and every other non-English language were checked with renders and synthetic speech only. See the known limits.

## What changed in 0.7.0

Japanese, Hindi and Tamil dictation in Beta, plus selected-text and dictionary fixes.

- Added: Dictation in Japanese, Hindi and Tamil, marked Beta in Settings. They use the multilingual Whisper Turbo model, a separate 1.6 GB download. Live words are unavailable whenever Whisper Turbo is used, including English takes in an Auto-detect set that contains them. Auto-detect candidate sets can include them. A take, a Setup test take or a file import keeps its starting language if Settings changes mid-take.
- Changed: The website typing speed test has a Start typing button and a 3-2-1 countdown.
- Fixed: Selected-text cleanup applies the website tone, then the app tone, then the global tone, and reads the selection off the main thread with a timeout. Also punctuation near a saved multiword term, cleanup timeout fallbacks that skipped saved phrases, dictionary rule usage counts with boundary apostrophes, and the streak when travel moves the local date backward.

> [!NOTE]
> Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release. Japanese, Hindi and Tamil, their 1.6 GB model download and every other non-English language were checked with renders and synthetic speech only. See the known limits.

## What changed in 0.6.0

Dictation in 25 languages, a mouse-button trigger, dictionary import and export, and cleanup instructions.

- Added: Dictation in 25 languages. Auto-detect is the default. Thorough cleanup covers English, German, Spanish, French, Italian, Portuguese, Dutch, Polish and Russian, and the rest get Basic cleanup. Fillers, spoken commands, counted lists and number formatting are English only.
- Added: A Mouse button setting (Middle, Back or Forward) as a dictation trigger, off by default.
- Added: Export the dictionary as CSV, and import Wispr Flow CSV and VoiceInk JSON dictionaries.
- Added: A Models page and a name accuracy card in Setup, a warning when a take heard nothing, and an optional test take.
- Added: Instructions for Thorough cleanup per app or website, three presets, and an Excited tone.
- Added: Website favicons in the Style lists, a Microphone page in Settings, and a Homebrew cask (`brew install --cask codeswhat/tap/mouthtype`).
- Changed: Names on screen is on by default. Releases are built in a repeatable mode.

> [!NOTE]
> Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release. Speech in languages other than English and the new screens were checked with renders and synthetic voices only. See the known limits.

## What changed in 0.5.0

Faster launch, dictation and Thorough cleanup, plus spoken slash commands for coding apps.

- Added: Spoken slash commands in terminals, editors, JetBrains, and the Claude, ChatGPT, Codex and Orca apps (plus claude.ai and chatgpt.com in a supported browser). "Slash research" types /research, and "dash", "hyphen" and "underscore" join more words. There's an Advanced toggle, on by default.
- Added: Show in Dock in Settings > Mac: Never, While a window is open (the default) or Always. The menu bar icon stays in every mode.
- Added: A docs site at docs.mouthtype.app, and real app icons in the Style lists.
- Added: The first-install download is a notarized DMG. Updates still use the ZIP.
- Changed: Launch and dictation are faster, and Thorough cleanup caches the unchanging part of its prompt between takes. The cleanup model unloads after 10 minutes without use and reloads on your next take.
- Fixed: Fn remap repairs, signal quits, paste into another process's field, cleanup of dictated quotes, and the sidebar ring on arrow-key selection. See the changelog for the full list.

> [!NOTE]
> Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release. See the known limits.

## What changed in 0.4.0

Mouthtype is now one redesigned window, with automation and Transform Selection added.

- Changed: One redesigned window with a new palette and SF Symbols in the sidebar: Home, Stats, Dictionary, Transforms, Style, Appearance and a Settings modal.
- Changed: Saved spellings and Phrases are now pages in the Mouthtype window instead of separate windows, and the shortcut recorder is a sheet on it.
- Changed: Set Up Mouthtype and Transcribe Audio File keep their own windows, since the menu bar opens them when no Mouthtype window is up. Leaving a page or closing the window with an unsaved draft still asks first.
- Added: Transform Selection in the menu bar cleans up a selection or runs Fix grammar, Make shorter, More formal or More casual on the Thorough model. A preview panel shows the original and an editable result; choose Accept, Copy result, Retry or Cancel. Accept replaces the text only if the app, field and selection are the same.
- Added: The Transforms page lists your phrases and these transforms, and Transcribe Audio File opens in its own window.
- Added: mouthtype:// URLs and a mouthtype command-line script can start, stop, toggle, cancel, copy-last and paste-last, and open a page. Those dictation commands are off until you turn on the automation switch.
- Added: With Boost my saved words on, an optional setting adds code names from VS Code, Cursor, Xcode and Terminal for one take.
- Changed: Quiet other audio is on by default, and stays off if you turned it off before.

> [!NOTE]
> Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release. See the known limits.

## What changed in 0.3.0

Home gets your recent takes and stats, and saved spellings get suggestions.

- Added: Open Mouthtype from the menu to a new Home page with your last 50 takes, newest first. Each take has Copy and Recover. Recover works for any take whose audio is still saved, and it offers the text again without changing the history entry. Home updates as you dictate.
- Added: The Stats page shows your stats: words today, this week and all time, a 30-day view, average and best speed, current and longest streak, biggest day, longest take, and time saved compared with typing at 40 WPM.
- Added: High scores on the Stats page show your fastest speed, biggest day, longest streak and longest take, each with its date. Everything is worked out on your Mac from your own history, and takes from secure fields are never counted.
- Added: Saved spellings now suggest spellings from your recent takes: names it keeps mishearing, brand names that come out lowercase, and words that get split apart, each with examples. Add, Remove or Dismiss a suggestion, and Undo right after. It also flags saved heard forms that rewrite everyday words.
- Changed: In Settings, with Keyboard navigation on, the page scrolls to follow <kbd>Tab</kbd> and <kbd>Shift</kbd>+<kbd>Tab</kbd>.

> [!NOTE]
> Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release.

## What changed in 0.2.0

Transform Selection chips, optional boosted recognition and per-rule cleanup levels.

- Added: The Fix grammar, Make shorter, More formal and More casual chips in the Transform Selection panel rewrite a selection on the Thorough model. You get an editable result with Accept, Retry and Cancel. Accept replaces the text only if the original app, field and selection still match, and <kbd>Command</kbd>+<kbd>Z</kbd> or Copy original gets the old text back.
- Added: Boost my saved words while recognising is off by default. It favours your saved spellings during recognition. First use downloads an English speech model of about 100 MB, and dictation never waits for it.
- Added: App and website rules can set a cleanup level as well as a tone, so cleanup can be on for one app while it's off elsewhere.
- Changed: Formal tone now removes or softens swearing at Basic, Fast and Thorough.
- Changed: Saved spellings warn when a heard form is an everyday word, like "win", and those aren't used as boost hints.
- Changed: In Settings, <kbd>Tab</kbd> reaches the page controls with macOS Keyboard navigation on, <kbd>Shift</kbd>+<kbd>Tab</kbd> steps back, and sidebar rows show focus.
- Fixed: The Appearance preview offers Light and Dark, and Glass no longer judges itself against Apple's placeholder picture when your wallpaper is a live one.

> [!NOTE]
> Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release.

## Earlier candidates

<details>
<summary>0.1.0 and rc.1 to rc.4</summary>

### 0.1.0

- Added: Since rc.4, a take cut off by quitting Mouthtype is offered for recovery on the next launch.
- Fixed in 0.2.0: <kbd>Tab</kbd> didn't reach Settings controls in 0.1.0.

### rc.4

RC.4 fixes what the rc.3 reviews found.

- Fixed: Pressing <kbd>Esc</kbd> to cancel a hands-free take no longer swallows the next Fn press.
- Fixed: Undo on a card works while an earlier take is still processing.
- Fixed: A {clipboard} phrase inserts what you copied.
- Fixed: Arrow keys move through the Settings sidebar with macOS Keyboard navigation on or off.
- Unchanged: Recognition and cleanup. The docs add troubleshooting and known limits.

### rc.3

RC.3 fixes what the rc.2 reviews found.

- Fixed: The processing pill stays up while a take is being worked on, and a card's "Your text is safe" line comes back when it finishes.
- Fixed: Long Classic messages scroll.
- Fixed: The Hi-Fi card falls back to the Classic card for text its pixel font can't draw, and its close button is easier to hit.
- Fixed: Glass no longer renders smoked on the first press after changing style or size in Settings.
- Unchanged: Recognition, cleanup and delivery.

### rc.2

- Added: The menu bar icon is lips that open with your voice. The app icon and the first-run setup window are redrawn, and Settings has a new layout with a glass sidebar.
- Added: Pill size is Automatic, Standard or Large, and Pill style adds Glass, Matrix and Minimal beside Classic and Hi-Fi.
- Added: Delivery cards follow the chosen style and size, including a pixel-art card for Hi-Fi.
- Added: Appearance has a live preview with a Light or Dark swatch, and Hi-Fi has a readout colour. Glass and the glass windows use a solid background under Reduce Transparency.
- Changed: Update checks are now on by default without a prompt. Dictation, cleanup and delivery behavior did not change.

> [!NOTE]
> The new interface has automated and offscreen rendering checks only; physical acceptance of it has not been done.

### Daily-use hardening in rc.1

- Changed: Ordinary delivery waits for a previous owned clipboard read before replacing it. If that read cannot be established within the bound, the new take remains recoverable. Check the destination before retrying.
- Changed: Normal Quit first preserves active and queued capture audio, then settles Mouthtype’s clipboard changes without overwriting a newer user copy. A failed save keeps the app open so Quit can be retried; no late model result is pasted during shutdown. If history storage is unavailable but WAV preservation succeeds, recovery may require opening the saved file from the local data directory.
- Changed: Saved Recordings loads when opened and keeps older audio accessible through pages.
- Changed: Recording starts before detailed Accessibility context lookup, while delivery keeps its focus checks.
- Fixed: An incomplete cleanup-model cache can be repaired with Download.
- Fixed: Basic fallback honors saved spellings and the spoken commands/lists choice.
- Fixed: The empty microphone priority list keeps System Default fallback enabled until an input is added.

Synthetic recognition checks cover clean/noisy speech and a repeated 19-minute clip. The measurements are in the repository and are not published on the website. Those checks do not establish physical microphone, sleep, Bluetooth or end-to-end delivery acceptance.

</details>

## Shortcuts and Settings

Open **Settings…** to change the dictation shortcut, recording behavior, microphone and sounds on General, launch at login on Mac, and the cleanup level and models on Style.

| Setting | Where | What |
| --- | --- | --- |
| Recording behavior | General | **Hold to talk** is the default. **Press to toggle** starts recording on one press and stops and inserts on the next. Changing behavior cancels an active recording. |
| Microphone | General | System Default, a named microphone or an opt-in Priority list. A change applies to the next take. |
| Quiet other audio | General | On by default from 0.4.0 and still off for anyone who turned it off, for supported output devices. |
| Live words | General | Optional and off by default. Shows provisional words above the pill. |
| Writing | Style | Cleanup level, global tone, saved spellings, phrases and optional per-app and website rules. |
| Appearance | Appearance | Classic/Hi-Fi, Hi-Fi sizing and fonts. |
| Health | Settings > Health | Model, permission and input status. |
| Advanced | Settings > Advanced | The set-once options. |

The menu is plain text, with no pill style, font, cleanup or login-item controls; those live in the Mouthtype window. Recent Takes is collapsed in the menu rather than filling the daily dropdown.

### Recording behavior

Choose **Press to toggle** to press your shortcut once to start recording, release it while speaking, then press it again to stop and insert.

- In Hold mode, double-tap the shortcut for hands-free recording; tap it to stop. <kbd>Fn</kbd>+<kbd>Space</kbd> also locks the default Fn shortcut.
- <kbd>Esc</kbd> cancels and offers Undo for five seconds. If <kbd>Esc</kbd> itself is your dictation shortcut, use the menu’s Cancel action.
- Caps Lock uses press-to-start/press-to-stop even in Hold mode; its system Caps Lock state may also change.
- Some system-reserved/media keys may be handled by macOS first.
- Paste Last Take (<kbd>Control</kbd>+<kbd>Command</kbd>+<kbd>V</kbd>) pastes the last delivered take, and Copy Last Take (<kbd>Control</kbd>+<kbd>Command</kbd>+<kbd>C</kbd>) copies it.

### Shortcut recorder

The shortcut recorder accepts a key or modifier combination.

- Click Change, which opens a sheet on the Mouthtype window, press the shortcut, release all keys, then Save.
- Cancel or <kbd>Esc</kbd> keeps the previous shortcut; Use Fn / Globe restores the default.
- Your shortcut is reserved for Mouthtype while it runs, including a bare letter.
- A shortcut matching Paste Last Take or Copy Last Take takes precedence over that action.

### Microphone and live words

The priority list chooses the first connected listed input at the start of a take; System Default fallback is a separate choice. Fixed microphone choices keep their unavailable-input behavior. Mouthtype remembers the chosen device and reports when it is missing. It does not change the Mac’s system input.

Quiet other audio restores only output changes Mouthtype owns; hardware behavior still needs tester feedback.

Live words finishes through full transcription and inserts once. Preview work is bounded to an eight-second audio window; that is not a wall-clock deadline. Final transcription waits for any already-running preview model work to finish.

### Writing and rules

- Website domains include subdomains; the most specific domain wins before the app rule and the default when the browser exposes its document URL. Missing URL support falls back, and URLs are not retained.
- Your own rules start empty. Built-in app and website lists carry their own tones, and everything else uses the default tone.
- Saved spellings supports Import CSV with name or heard,written headers. Review the preview and confirm before applying; malformed or conflicting rows block the import. More… also imports Wispr Flow CSV and VoiceInk JSON dictionaries and exports the Dictionary as CSV.
- Formal removes swear words used as exclamations or emphasis at Basic, Fast and Thorough (Off bypasses cleanup). Thorough also swaps a swear noun for a plain word, while Basic and Fast only remove exclamations and emphasis; tone does not otherwise authorize paraphrasing.
- Default appearance stays simple; Override individual fonts reveals independent Heading, Body and Readout choices.

## Clean selected text

Select text in an accessible editable field, then choose **Transform Selection**, then **Clean up** (it uses the tone that applies to the app you're in) or one of the AI transforms.

- The panel strikes through removed words in the original and highlights what changed in the result, which you can edit.
- Choose **Accept** to request replacement of the original selection. The app, field, range and text must still match. If they don't, the panel says so, disables Accept and makes **Copy result** the main button.
- Password fields are excluded. The chips switch transforms inside the panel.
- There is no automatic paste.
- **Edit Transforms…** opens the Transforms page. Saved phrases are no longer in this menu; they're inserted by voice.

Check the original field after Accept. See [writing tools](https://docs.mouthtype.app/cleanup-and-style/writing-tools/) for browser, device and selection limits.

## Transcribe an audio file

Choose **Transcribe Audio File…** in the menu (it opens the Transcribe Audio File window, and Home has a button for it too), then select one WAV, AIFF or M4A file up to 10 minutes and 512 MB. Mouthtype uses the speech model already loaded on your Mac. Your original file stays unchanged.

- Preparing and Transcribing show actual work stages.
- Cancel, or close the Transcribe Audio File window, to cancel the import. Closing or switching the Mouthtype window doesn't. Cancellation may wait for the current recognition operation to return.
- The full raw result is selectable: explicitly use **Copy** or **Save Text…** to export UTF-8 text. Saving over the original audio is refused.
- Imports do not apply cleanup, saved spellings or phrases, paste automatically, or change dictation history/statistics.

Finish any dictation or recovery before importing; new recording, recovery and update installation wait while the import or its cancellation settles.

## Updates

> [!NOTE]
> Alpha.1 through alpha.3 do not contain an updater. Download the current Mac release once from the website and replace the old app to get it.

Use **Check for Updates…** in Mouthtype’s menu to check manually. Automatic update checks are on by default without a prompt; you can turn them off in Settings > Mac. Update checks and update downloads use HTTPS. They do not include your transcripts or recordings, and anonymous system profiling is disabled.

Available updates show a notification and release notes. Choose installation in the app. Updates use signed archives, a signed feed and Developer ID signatures. Installation waits while dictation, recovery or file transcription is active. Automatic silent installation is disabled. Do not remove your data folder when upgrading.

## Known limitations

For fixes to common problems and the full list of what this release doesn't cover, see https://docs.mouthtype.app/troubleshooting/ and https://docs.mouthtype.app/reference/known-limits/.

- Names and context-dependent recognition can be wrong. A real example was testing recognized as dusting across takes. Check text before sending. Mouthtype does not read previous chat messages to resolve it.
- Broader browser/terminal/Electron behavior, clipboard restoration, microphone removal, silence, stop-cue counts and explicit Undo need more live coverage. The false-failure warning behavior is not fully verified.
- Long terminal paste splitting is off by default. Splitting adds no Return between parts. If the app is on the Press Return after inserting list, one Return can follow the whole paste once it is confirmed.
- Setup’s microphone status can lag a recovered input until you return to the app and refresh it. Device transitions still need live coverage.
- First installation and model downloads on another Mac need confirmation. Existing developer-machine grants and caches do not verify that path.
- Linux has an experimental source-only daemon/CLI candidate. Arch/Omarchy is an active acceptance target. Container and headless component checks do not establish physical microphone or Hyprland support. See Linux source testing below.

> [!WARNING]
> An interrupted split paste may already have inserted text. Inspect the field before copying the full recovery text.

## Linux source testing

The source archive at https://mouthtype.app/source includes `tools/linux-desktop/README.md`, an experimental daemon/CLI, an explicit speech-preparation helper and an Omarchy bar plugin (`tools/omarchy-plugin`) with a floating pill. The initial target is Linux x86_64, Arch/Omarchy, Hyprland and PipeWire. There is no supported Linux desktop release.

- The source includes a local Arch test-package builder, optional saved spellings, phrase replacements, single-file audio transcription, optional paste or typing delivery and cleanup (Basic, plus local Fast and Thorough models that are prepared on request).
- Delivery is recovery-only and cleanup is off by default.
- The plugin installer enables a login service unless you pass `--no-autostart`.
- Linux has no live word previews, and its Thorough model is Qwen3 4B, not the Mac model.
- The install checklist is at https://mouthtype.app/linux/agent-install.md.

Follow that README to install the launcher into a chosen prefix and run `tools/linux-desktop/setup_speech.py` with a new destination outside the checkout. Preparation downloads the pinned speech archive, verifies its hashes and installs pinned binary packages into a dedicated environment. It does not record, load models, register shortcuts, modify compositor configuration or start a service. Start the foreground service explicitly afterward. Recovery-only delivery is the default and makes no clipboard or key changes; automatic typing is an explicit opt-in with documented compositor/field limitations.

Cleanup is off by default; it runs before literal saved-spelling/phrase expansion and keeps raw recognition recoverable. Automatic typing refuses multiline/control-bearing text rather than sending Return or Tab. Follow the source guide for phrase dates, explicit clipboard-context opt-in and formatting limitations.

> [!NOTE]
> Synthetic audio, process/IPC, real headless Wayland components and remote speech-runtime checks are evidence for those components, not certification of a physical Arch/Omarchy desktop. Follow the source README for prerequisites and acceptance steps.

## Local data and removal

History, dictionary, settings and recordings stay on your Mac. Text history is retained indefinitely.

- In **Settings > Advanced > Storage**, choose 14, 30 or 90 days, or No age limit, plus a 2 GB or 10 GB limit. Defaults stay 90 days and 2 GB.
- Changes apply at the next launch to completed Mouthtype recordings only; unfinished recordings and recovery audio are exempt. Text and timings stay. No age limit still has a size limit.
- Removed audio cannot be restored. See [saved audio](https://docs.mouthtype.app/privacy-and-data/saved-audio/).
- The data directory is `~/Library/Application Support/Mouthtype`. Uninstalling the app does not remove it.

Quit Mouthtype before removing the app. Delete the data folder only if you intend to erase it.

## Report a problem

Include the version, macOS version, destination app, what you said, what appeared and any warning. Say whether text appeared once, twice or not at all. Send only the transcript/audio you choose to share. Open an issue at https://github.com/CodesWhat/mouthtype/issues, or contact the person who shared Mouthtype with you.

## Release evidence

Maintainer notes on what was and wasn't verified. Users can skip this section.

### Current release-candidate evidence

The built-in output passed ten actual quiet/restore cycles after reproducing the delayed mute-notification failure. Separate native checks preserved an observed unmute/remute and a volume adjustment. The tests restored their owned output baseline. Quieting is on by default; this does not certify other output devices.

Private native pasteboard checks preserve rich/multiple items through a promise read and restoration, and retain a newer copy during shutdown. They emit no keyboard events and never use the general clipboard. A disposable copy of existing saved data opens through the production store with unchanged schema and value digests; a WAL fixture verifies committed rows are included. These checks do not establish fresh-install permissions or normal updater installation/relaunch.

TextEdit and Chrome each passed two physical ordered takes on beta.1; provisional live words and one final insertion were observed. That is historical evidence for unchanged delivery code, not a new RC hardware matrix. Fresh installation, normal updater installation/relaunch, Settings keyboard/VoiceOver and additional supported hardware remain unverified. The maintainer ended the manual QA loop; no manual handoff is pending.

### What has been checked

Automated checks cover shortcut activation, release ordering, modifier-only combinations, Hold/Toggle transitions, autorepeat, cancellation, saved preferences, failed-listener retries, existing Fn behavior, paste and recovery. Offscreen rendering covers Settings at normal/minimum size and Hi-Fi geometry. Controlled updater checks cover idle/busy gating and preference behavior without installing over a running app. File checks cover actual WAV/AIFF/AAC decoding, multichannel downmix, limits, cancellation, exact Unicode export and source preservation. They do not establish recognition quality for imported recordings.

Earlier physical native checks covered microphone dictation, consecutive-take spacing, Paste Last, Escape without late insertion, and force-quit recovery through Recover then Copy without automatic pasting. The maintainer also completed four actual stop/resume takes with one insertion and boundary spaces. These earlier checks are historical evidence; current-build fresh installation, physical toggle/custom-key dictation, update installation and broad app coverage still need tester confirmation. Unknown delivery status is not proof that text failed to land.
