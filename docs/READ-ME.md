# Mouthtype 0.3.0

Local dictation for Apple Silicon Macs running macOS 26 or later. Hold Fn, speak, release, and clean text is pasted where you're typing. Recognition and cleanup run on your Mac. Fresh installation, Bluetooth and USB microphones and VoiceOver weren't verified on a device for this release; see the known limits.

## Install

1. Download the ZIP from https://mouthtype.app/download and expand it in Finder.
2. Drag Mouthtype.app into Applications. Quit an older running Mouthtype before replacing it.
3. Open Mouthtype from Applications. This distribution is Developer ID signed and notarized. If macOS rejects it, record the exact message; do not disable Gatekeeper.
4. Follow Set Up Mouthtype, one card at a time. Allow Microphone access, then grant Accessibility in System Settings and return to the app. Each card advances when its prerequisite is ready. Reopen setup from Settings → General if you defer it.
5. Wait for the speech model to download and prepare. Downloads need internet access; transcription and cleanup run on your Mac. Basic cleanup works without a cleanup-model download. Optional Fast is roughly 1.4 GB; Thorough is roughly 5.2 GB.
6. Click a blank TextEdit document. Hold Fn, say a sentence, then release. Wait for text to appear. Dictate another sentence without clicking or typing between takes. Confirm one insertion per take and a space between them.

The app’s Resources folder contains these notes and its license. Corresponding release source is available from https://mouthtype.app/source; the development repository remains private.

## What changed in 0.3.0

Open Mouthtype from the menu to a new Home page with your last 50 takes, newest first. Each take has Copy and Recover. Recover works for any take whose audio is still saved, and it offers the text again without changing the history entry. Home updates as you dictate.

Home also shows your stats: words today, this week and all time, a 30-day view, average and best speed, current and longest streak, biggest day, longest take, and time saved compared with typing at 40 WPM. High scores on the same page show your fastest speed, biggest day, longest streak and longest take, each with its date. Everything is worked out on your Mac from your own history, and takes from secure fields are never counted.

Saved spellings now suggest spellings from your recent takes: names it keeps mishearing, brand names that come out lowercase, and words that get split apart, each with examples. Add, Remove or Dismiss a suggestion, and Undo right after. It also flags saved heard forms that rewrite everyday words.

In Settings, with Keyboard navigation on, the page scrolls to follow Tab and Shift-Tab.

Saved spellings and Phrases are now pages in the Mouthtype window instead of separate windows, and the shortcut recorder is a sheet on it. Set Up Mouthtype and Transcribe Audio File keep their own windows, since the menu bar opens them when no Mouthtype window is up. Leaving a page or closing the window with an unsaved draft still asks first.

Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release.

## What changed in 0.2.0

The Fix grammar, Make shorter, More formal and More casual chips in the Transform Selection panel rewrite a selection on the Thorough model. You get an editable result with Accept, Retry and Cancel. Accept replaces the text only if the original app, field and selection still match, and Cmd-Z or Copy original gets the old text back.

Boost my saved words while recognising is off by default. It favours your saved spellings during recognition. First use downloads an English speech model of about 100 MB, and dictation never waits for it.

App and website rules can set a cleanup level as well as a tone, so cleanup can be on for one app while it's off elsewhere. Formal tone now removes or softens swearing at Basic, Fast and Thorough. Saved spellings warn when a heard form is an everyday word, like "win", and those aren't used as boost hints.

In Settings, Tab reaches the page controls with macOS Keyboard navigation on, Shift-Tab steps back, and sidebar rows show focus. The Appearance preview offers Light and Dark, and Glass no longer judges itself against Apple's placeholder picture when your wallpaper is a live one.

Fresh installation, VoiceOver, and Bluetooth and USB microphones weren't verified on a device for this release.

## What changed in 0.1.0

Since rc.4, a take cut off by quitting Mouthtype is offered for recovery on the next launch. Tab didn't reach Settings controls in 0.1.0; that is fixed in 0.2.0.

## What changed in rc.4

RC.4 fixes what the rc.3 reviews found. Pressing Esc to cancel a hands-free take no longer swallows the next Fn press, undo on a card works while an earlier take is still processing, and a {clipboard} phrase inserts what you copied. Arrow keys move through the Settings sidebar with macOS Keyboard navigation on or off. Recognition and cleanup are unchanged. The docs add troubleshooting and known limits.

## What changed in rc.3

RC.3 fixes what the rc.2 reviews found. The processing pill stays up while a take is being worked on, and a card's "Your text is safe" line comes back when it finishes. Long Classic messages scroll. The Hi-Fi card falls back to the Classic card for text its pixel font can't draw, and its close button is easier to hit. Glass no longer renders smoked on the first press after changing style or size in Settings. Recognition, cleanup and delivery are unchanged.

## What changed in rc.2

The menu bar icon is lips that open with your voice. The app icon and the first-run setup window are redrawn, and Settings has a new layout with a glass sidebar. Pill size is Automatic, Standard or Large, and Pill style adds Glass, Matrix and Minimal beside Classic and Hi-Fi. Delivery cards follow the chosen style and size, including a pixel-art card for Hi-Fi. Appearance has a live preview with a Light or Dark swatch, and Hi-Fi has a readout colour. Glass and the glass windows use a solid background under Reduce Transparency.

Update checks are now on by default without a prompt. Dictation, cleanup and delivery behavior did not change. The new interface has automated and offscreen rendering checks only; physical acceptance of it has not been done.

## Daily-use hardening in rc.1

Ordinary delivery waits for a previous owned clipboard read before replacing it. If that read cannot be established within the bound, the new take remains recoverable. Check the destination before retrying. Normal Quit first preserves active and queued capture audio, then settles Mouthtype’s clipboard changes without overwriting a newer user copy. A failed save keeps the app open so Quit can be retried; no late model result is pasted during shutdown. If history storage is unavailable but WAV preservation succeeds, recovery may require opening the saved file from the local data directory.

Saved Recordings loads when opened and keeps older audio accessible through pages. Recording starts before detailed Accessibility context lookup, while delivery keeps its focus checks. An incomplete cleanup-model cache can be repaired with Download. Basic fallback honors saved spellings and the spoken commands/lists choice. The empty microphone priority list keeps System Default fallback enabled until an input is added.

Synthetic recognition checks cover clean/noisy speech and a repeated 19-minute clip. The measurements are in the repository and are not published on the website. Those checks do not establish physical microphone, sleep, Bluetooth or end-to-end delivery acceptance.

## Shortcuts and Settings

Open **Settings… → General** to change the dictation shortcut, recording behavior, cleanup model, sounds and launch at login. **Hold to talk** remains the default. Choose **Press to toggle** to press your shortcut once to start recording, release it while speaking, then press it again to stop and insert. Changing behavior cancels an active recording.

Choose System Default, a named microphone or an opt-in Priority list in General. The priority list chooses the first connected listed input at the start of a take; System Default fallback is a separate choice. Fixed microphone choices keep their unavailable-input behavior. Mouthtype remembers the chosen device and reports when it is missing. It does not change the Mac’s system input. A change applies to the next take. Quiet other audio is a control, on by default from 0.4.0 and still off for anyone who turned it off, for supported output devices. It restores only output changes Mouthtype owns; hardware behavior still needs tester feedback.

**Live words** in General is optional and off by default. It shows provisional words above the pill. The finished take still goes through full transcription and inserts once. Preview work is bounded to an eight-second audio window; that is not a wall-clock deadline. Final transcription waits for any already-running preview model work to finish.

The shortcut recorder accepts a key or modifier combination. Click Change, which opens a sheet on the Mouthtype window, press the shortcut, release all keys, then Save. Cancel or Escape keeps the previous shortcut; Use Fn / Globe restores the default. Your shortcut is reserved for Mouthtype while it runs, including a bare letter. A shortcut matching Paste Last Take or Copy Last Take takes precedence over that action.

In Hold mode, double-tap the shortcut for hands-free recording; tap it to stop. Fn+Space also locks the default Fn shortcut. Escape cancels and offers Undo for five seconds. If Escape itself is your dictation shortcut, use the menu’s Cancel action. Caps Lock uses press-to-start/press-to-stop even in Hold mode; its system Caps Lock state may also change. Some system-reserved/media keys may be handled by macOS first. Paste Last Take (Control+Command+V) pastes the last delivered take, and Copy Last Take (Control+Command+C) copies it.

**Writing** includes cleanup level, global tone, saved spellings, phrases and optional per-app and website rules that set tone, cleanup level or both. Website domains include subdomains; the most specific domain wins before the app rule and the default when the browser exposes its document URL. Missing URL support falls back, and URLs are not retained. Saved spellings supports Import CSV with name or heard,written headers. Review the preview and confirm before applying; malformed or conflicting rows block the import. Rules start empty and fall back to the global tone. Formal removes swear words used as exclamations or emphasis at Basic, Fast and Thorough (Off bypasses cleanup), and Thorough also swaps a swear noun for a plain word, while Basic and Fast only remove exclamations and emphasis; tone does not otherwise authorize paraphrasing. **Appearance** includes Classic/Hi-Fi, Hi-Fi sizing and fonts. Default stays simple; Override individual fonts reveals independent Heading, Body and Readout choices. **Settings > Health** holds model, permission and input status, and **Settings > Advanced** holds the set-once options. Recent Takes is collapsed in the menu rather than filling the daily dropdown. The menu is plain text, with no pill style, font, cleanup or login-item controls; those live in the Mouthtype window.

## Clean selected text

Select text in an accessible editable field, then choose **Transform Selection**, then **Clean up** (it uses the tone that applies to the app you're in) or one of the AI transforms. The panel names the app the text came from, strikes through removed words in the original and highlights what changed in the result, which you can edit. Choose **Accept** to request replacement of the original selection. The app, field, range and text must still match. If they don't, the panel says so, disables Accept and makes **Copy result** the main button. Password fields are excluded. The chips switch transforms inside the panel. There is no automatic paste. **Edit Transforms…** opens the Transforms page. Saved phrases are no longer in this menu; they're inserted by voice. Check the original field after Accept. See [writing tools](https://mouthtype.app/docs/#cleanup) for browser, device and selection limits.

## Transcribe an audio file

Choose **Transcribe Audio File…** in the menu (it opens the Transcribe Audio File window, and Home has a button for it too), then select one WAV, AIFF or M4A file up to 10 minutes and 512 MB. Mouthtype uses the speech model already loaded on your Mac. Your original file stays unchanged.

Preparing and Transcribing show actual work stages. Cancel, or close the Mouthtype window, to cancel the import. Switching to another page keeps it running. Cancellation may wait for the current recognition operation to return. The full raw result is selectable: explicitly use **Copy** or **Save Text…** to export UTF-8 text. Saving over the original audio is refused.

Imports do not apply cleanup, saved spellings or phrases, paste automatically, or change dictation history/statistics. Finish any dictation or recovery before importing; new recording, recovery and update installation wait while the import or its cancellation settles.

## Updates

Alpha.1 through alpha.3 do not contain an updater. Download the current Mac release once from the website and replace the old app to get it.

Use **Check for Updates…** in Mouthtype’s menu to check manually. Automatic update checks are on by default without a prompt; you can turn them off in Settings > Mac. Update checks and update downloads use HTTPS. They do not include your transcripts or recordings, and anonymous system profiling is disabled.

Available updates show a notification and release notes. Choose installation in the app. Updates use signed archives, a signed feed and Developer ID signatures. Installation waits while dictation, recovery or file transcription is active. Automatic silent installation is disabled. Do not remove your data folder when upgrading.

## Current release-candidate evidence

The built-in output passed ten actual quiet/restore cycles after reproducing the delayed mute-notification failure. Separate native checks preserved an observed unmute/remute and a volume adjustment. The tests restored their owned output baseline. Quieting is on by default; this does not certify other output devices.

Private native pasteboard checks preserve rich/multiple items through a promise read and restoration, and retain a newer copy during shutdown. They emit no keyboard events and never use the general clipboard. A disposable copy of existing saved data opens through the production store with unchanged schema and value digests; a WAL fixture verifies committed rows are included. These checks do not establish fresh-install permissions or normal updater installation/relaunch.

TextEdit and Chrome each passed two physical ordered takes on beta.1; provisional live words and one final insertion were observed. That is historical evidence for unchanged delivery code, not a new RC hardware matrix. Fresh installation, normal updater installation/relaunch, Settings keyboard/VoiceOver and additional supported hardware remain unverified. The maintainer ended the manual QA loop; no manual handoff is pending.

## What has been checked

Automated checks cover shortcut activation, release ordering, modifier-only combinations, Hold/Toggle transitions, autorepeat, cancellation, saved preferences, failed-listener retries, existing Fn behavior, paste and recovery. Offscreen rendering covers Settings at normal/minimum size and Hi-Fi geometry. Controlled updater checks cover idle/busy gating and preference behavior without installing over a running app. File checks cover actual WAV/AIFF/AAC decoding, multichannel downmix, limits, cancellation, exact Unicode export and source preservation. They do not establish recognition quality for imported recordings.

Earlier physical native checks covered microphone dictation, consecutive-take spacing, Paste Last, Escape without late insertion, and force-quit recovery through Recover then Copy without automatic pasting. Scott also completed four actual Orca stop/resume takes with one insertion and boundary spaces. These earlier checks are historical evidence; current-build fresh installation, physical toggle/custom-key dictation, update installation and broad app coverage still need tester confirmation. Unknown delivery status is not proof that text failed to land.

## Known limitations

For fixes to common problems and the full list of what this release doesn't cover, see https://mouthtype.app/docs/#troubleshooting and https://mouthtype.app/docs/#known-limits.

- Names and context-dependent recognition can be wrong. A real example was testing recognized as dusting across takes. Check text before sending. Mouthtype does not read previous chat messages to resolve it.
- Broader browser/terminal/Electron behavior, clipboard restoration, microphone removal, silence, stop-cue counts and explicit Undo need more live coverage. Orca’s false-failure warning behavior is not fully verified.
- Long terminal paste splitting is off by default. An interrupted split paste may already have inserted text. Inspect the field before copying the full recovery text. No Return is sent automatically.
- Setup’s microphone status can lag a recovered input until you return to the app and refresh it. Device transitions still need live coverage.
- First installation and model downloads on another Mac need confirmation. Existing developer-machine grants and caches do not verify that path.
- Linux has an experimental source-only daemon/CLI candidate. Arch/Omarchy is an active acceptance target. Container and headless component checks do not establish physical microphone or Hyprland support. See Linux source testing below.

## Linux source testing

The source archive at https://mouthtype.app/source includes `tools/linux-desktop/README.md`, an experimental daemon/CLI, an explicit speech-preparation helper and an Omarchy bar plugin (`tools/omarchy-plugin`) with a floating pill. The initial target is Linux x86_64, Arch/Omarchy, Hyprland and PipeWire. There is no supported Linux desktop release. The source includes a local Arch test-package builder, optional saved spellings, phrase replacements, single-file audio transcription, optional paste or typing delivery and cleanup (Basic, plus local Fast and Thorough models that are prepared on request). Delivery is recovery-only and cleanup is off by default. The plugin installer enables a login service unless you pass `--no-autostart`. Linux has no live word previews, and its Thorough model is Qwen3 4B, not the Mac model. The install checklist is at https://mouthtype.app/linux/agent-install.md.

Follow that README to install the launcher into a chosen prefix and run `tools/linux-desktop/setup_speech.py` with a new destination outside the checkout. Preparation downloads the pinned speech archive, verifies its hashes and installs pinned binary packages into a dedicated environment. It does not record, load models, register shortcuts, modify compositor configuration or start a service. Start the foreground service explicitly afterward. Recovery-only delivery is the default and makes no clipboard or key changes; automatic typing is an explicit opt-in with documented compositor/field limitations.

Cleanup is off by default; it runs before literal saved-spelling/phrase expansion and keeps raw recognition recoverable. Automatic typing refuses multiline/control-bearing text rather than sending Return or Tab. Follow the source guide for phrase dates, explicit clipboard-context opt-in and formatting limitations.

Synthetic audio, process/IPC, real headless Wayland components and remote speech-runtime checks are evidence for those components, not certification of a physical Arch/Omarchy desktop. Follow the source README for prerequisites and acceptance steps.

## Local data and removal

History, dictionary, settings and recordings stay on your Mac. Text history is retained indefinitely. In **Settings > Advanced > Storage**, choose 14, 30 or 90 days, or No age limit, plus a 2 GB or 10 GB limit. Defaults stay 90 days and 2 GB. Changes apply at the next launch to completed Mouthtype recordings only; unfinished recordings and recovery audio are exempt. Text and timings stay. No age limit still has a size limit. Removed audio cannot be restored. See [saved audio](https://mouthtype.app/docs/#local-data). The data directory is `~/Library/Application Support/Mouthtype`. Uninstalling the app does not remove it. Quit Mouthtype before removing the app. Delete the data folder only if you intend to erase it.

## Report a problem

Include the version, macOS version, destination app, what you said, what appeared and any warning. Say whether text appeared once, twice or not at all. Send only the transcript/audio you choose to share. Contact the person who shared Mouthtype with you; repository members can also use its private issue tracker.
