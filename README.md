# Mouthtype

Local dictation for Apple Silicon Macs running macOS 26 or later.

Click a text field, hold Fn and speak, then release to paste. Double-tap Fn or press Fn+Space for hands-free dictation; tap Fn to stop. Esc cancels, with a five-second Undo window.

## Run from source

Install Xcode with Swift 6.2, then run `bash scripts/run-app.sh`. The script builds and opens a signed app bundle. A Developer ID identity keeps permission grants stable between builds; without one, builds use ad-hoc signing.

Allow Microphone and Accessibility access when macOS asks. The menu has links to those settings and **How to Use Mouthtype**. Fn remapping is enabled by default while Mouthtype runs; it hides the emoji picker and preserves Fn navigation combinations.

The speech model and a small speech detector download on first launch. The detector keeps empty recordings from becoming invented words. Download and loading status appear in the menu; **Retry Speech Model** appears if preparation fails. Transcription runs locally. Parakeet v3 decoding uses an English language hint to prevent accidental Cyrillic output; Whisper also requests English. Smart cleanup is a separate optional model download, with basic cleanup available without it.

Fast cleanup uses S1-mini by Superwhisper locally, a roughly 1.4 GB download. Thorough uses Gemma 4 E4B, a roughly 5.2 GB download. Both handle fillers, corrections and spoken technical notation while preserving wording. Neither mode authorizes paraphrasing or a more formal voice. Cleanup uses up to 600 characters before the cursor and 300 after it when available, excluding secure fields. Invalid output or a missed deadline delivers the basic cleanup instead. Known project spellings can be joined in clear software contexts, while ordinary phrases such as a boat in dry dock are preserved. In model-backed cleanup, dictionary entries that only join words are context hints; Basic retains literal dictionary replacements. Ambiguous names still have gaps, especially with Fast cleanup. Neither model is downloaded until requested. Switching models loads the selected cached model and unloads the inactive one after pending work finishes.

## Choose cleanup strength and writing style

Open **Cleanup** in the menu. **Level** chooses the cleanup path: Off keeps the recognized text, Basic applies local formatting rules, Fast adds S1-mini and Thorough uses Gemma. Both model modes preserve wording; they differ in speed and model capability, independently of Tone. Existing saved Light settings become Fast, and Medium becomes Thorough; Off, Basic and tone settings stay as saved.

**Tone** is a separate writing-style choice. **Formal** keeps sentence capitalization and punctuation. **Casual** keeps sentence capitalization and drops the final full stop. **Very Casual** also relaxes sentence capitalization while protecting names and technical spellings. Questions still keep their question marks. These presets don't add enthusiasm or rewrite your personality.

## Recovery and sound

If a paste fails or there's nowhere to paste, the result stays available to copy. **Paste Last** and **Copy Last** restore the latest saved transcript after restart. The menu also lists recent transcripts.

A recording interrupted by a crash can be recovered on the next launch. **Saved Recordings** makes older interrupted or failed recordings available to recover without pasting into the wrong app. Failed recovery keeps a Recover action so it can be retried. Recovery pauses new recordings until it finishes.

Click is the default sound set: a bright key-down thunk to start, a duller key-up thunk to stop, and matching lock and error cues. **Sounds** turns cues on or off. Other sound sets and a picker are deferred.

## Data

History, settings, dictionary and audio stay on this Mac. The default store is `~/Library/Application Support/Mouthtype/mouthtype.sqlite`; recordings are in its sibling `audio` directory. Text history is retained indefinitely. Audio cleanup runs at launch: files older than 90 days are removed, then the oldest remaining files until the archive fits within 2 GB. Model downloads require network access.

Run `swift test` to check the core, macOS integration logic and Fn guardian. The bundled app also has isolated paste and recovery self-tests, which take desktop focus and should be run only when the desktop is free. Those tests restrict keyboard events to their own process and refuse delivery when another app has focus. Live microphone quality and behavior in individual third-party apps still need their own checks.
