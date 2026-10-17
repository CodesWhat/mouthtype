# Mouthtype 0.1.0-alpha.6

Alpha for Apple Silicon Macs running macOS 26 or later. This is an early test build. Recognition, first installation and behavior in individual apps still need feedback.

## Install

1. Download the ZIP from https://mouthtype.app/download and expand it in Finder.
2. Drag Mouthtype.app into Applications. Quit an older running Mouthtype before replacing it.
3. Open Mouthtype from Applications. This distribution is Developer ID signed and notarized. If macOS rejects it, record the exact message; do not disable Gatekeeper.
4. Follow Set Up Mouthtype, one card at a time. Allow Microphone access, then grant Accessibility in System Settings and return to the app. Each card advances when its prerequisite is ready. Reopen setup from Settings → General if you defer it.
5. Wait for the speech model to download and prepare. Downloads need internet access; transcription and cleanup run on your Mac. Basic cleanup works without a cleanup-model download. Optional Fast is roughly 1.4 GB; Thorough is roughly 5.2 GB.
6. Click a blank TextEdit document. Hold Fn, say a sentence, then release. Wait for text to appear. Dictate another sentence without clicking or typing between takes. Confirm one insertion per take and a space between them.

The app’s Resources folder contains these notes and its license. Corresponding release source is available from https://mouthtype.app/source; the development repository remains private.

## Shortcuts and Settings

Open **Settings… → General** to change the dictation shortcut, recording behavior, cleanup model, sounds and launch at login. **Hold to talk** remains the default. Choose **Press to toggle** to press your shortcut once to start recording, release it while speaking, then press it again to stop and insert. Changing behavior cancels an active recording.

Choose System Default or a named microphone in General. Mouthtype remembers the chosen device and reports when it is missing. It does not change the Mac’s system input. A change applies to the next take. Quiet other audio is an optional, default-off control for supported output devices. It restores only output changes Mouthtype owns; hardware behavior still needs tester feedback.

Live text preview is optional and off by default. It shows provisional words above the pill. The finished take still goes through full transcription and inserts once. Preview work is bounded to an eight-second audio window; that is not a wall-clock deadline. Final transcription waits for any already-running preview model work to finish.

The shortcut recorder accepts a key or modifier combination. Click Change, press the shortcut, release all keys, then Save. Cancel keeps the previous shortcut; Use Fn / Globe restores the default. Your shortcut is reserved for Mouthtype while it runs, including a bare letter. A shortcut matching Paste Last or Copy Last takes precedence over that action.

In Hold mode, double-tap the shortcut for hands-free recording; tap it to stop. Fn+Space also locks the default Fn shortcut. Escape cancels and offers Undo for five seconds. If Escape itself is your dictation shortcut, use the menu’s Cancel action. Caps Lock uses press-to-start/press-to-stop even in Hold mode; its system Caps Lock state may also change. Some system-reserved/media keys may be handled by macOS first. Control+Command+V pastes the last delivered take.

**Writing** includes cleanup level, global tone, saved spellings, phrases and optional per-app tone rules. Saved spellings supports Import CSV with name or heard,written headers. Review the preview and confirm before applying; malformed or conflicting rows block the import. Rules start empty and fall back to the global tone. Tone does not authorize paraphrasing. **Appearance** includes Classic/Hi-Fi, Hi-Fi sizing and fonts. Default stays simple; Override individual fonts reveals independent Heading, Body and Readout choices. **Diagnostics** holds model, permission, input and advanced controls. Recent takes are collapsed in the menu rather than filling the daily dropdown.

## Updates

Alpha.1 through alpha.3 do not contain an updater. Download alpha.5 once from the website and replace the old app to get it.

Use **Check for Updates…** in Mouthtype’s menu to check manually. Sparkle asks whether to enable automatic update checks; you can change that choice in General. Update checks and update downloads use HTTPS. They do not include your transcripts or recordings, and anonymous system profiling is disabled.

Available updates show a notification and release notes. Choose installation in the app. Updates use signed archives, a signed feed and Developer ID signatures. Installation waits while a dictation or recovery is active. Automatic silent installation is disabled. Do not remove your data folder when upgrading.

## What has been checked

Automated checks cover shortcut activation, release ordering, modifier-only combinations, Hold/Toggle transitions, autorepeat, cancellation, saved preferences, failed-listener retries, existing Fn behavior, paste and recovery. Offscreen rendering covers Settings at normal/minimum size and Hi-Fi geometry. Controlled updater checks cover idle/busy gating and preference behavior without installing over a running app.

Earlier physical native checks covered microphone dictation, consecutive-take spacing, Paste Last, Escape without late insertion, and force-quit recovery through Recover then Copy without automatic pasting. Scott also completed four actual Orca stop/resume takes with one insertion and boundary spaces. These earlier checks are historical evidence; current-build fresh installation, physical toggle/custom-key dictation, update installation and broad app coverage still need tester confirmation. Unknown delivery status is not proof that text failed to land.

## Known limitations

- Names and context-dependent recognition can be wrong. A real example was testing recognized as dusting across takes. Check text before sending. Mouthtype does not read previous chat messages to resolve it.
- Broader browser/terminal/Electron behavior, clipboard restoration, microphone removal, silence, stop-cue counts and explicit Undo need more live coverage. Orca’s false-failure warning behavior is not fully verified.
- Long terminal paste splitting is off by default. An interrupted split paste may already have inserted text. Inspect the field before copying the full recovery text. No Return is sent automatically.
- Setup’s microphone status can lag a recovered input until you return to the app and refresh it. Device transitions still need live coverage.
- First installation and model downloads on another Mac need confirmation. Existing developer-machine grants and caches do not verify that path.
- Linux has an experimental source-only daemon/CLI candidate. Arch/Omarchy is an active acceptance target. Container and headless component checks do not establish physical microphone or Hyprland support.

## Local data and removal

History, dictionary, settings and recordings stay on your Mac. Text history is retained indefinitely; audio defaults to 90 days or 2 GB. The data directory is `~/Library/Application Support/Mouthtype`. Uninstalling the app does not remove it. Quit Mouthtype before removing the app. Delete the data folder only if you intend to erase it.

## Report a problem

Include the version, macOS version, destination app, what you said, what appeared and any warning. Say whether text appeared once, twice or not at all. Send only the transcript/audio you choose to share. Contact the person who shared Mouthtype with you; repository members can also use its private issue tracker.
