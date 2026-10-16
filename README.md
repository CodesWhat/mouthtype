# Mouthtype

Local dictation for Apple Silicon Macs running macOS 26 or later.

Click a text field, hold Fn and speak, then release to paste. Double-tap Fn or press Fn+Space for hands-free dictation; tap Fn to stop. Esc cancels, with a five-second Undo window.

## Private alpha

The current private alpha is `0.1.0-alpha.3` for Apple Silicon Macs on macOS 26 or later. Download the notarized ZIP from this private repository’s Releases page and follow [the alpha install notes](docs/ALPHA.md). Repository access is required for the download. Known limitations and feedback details are listed there.

For a larger Winamp-style pill, choose **Pill Style → Hi-Fi Size → Large (2×)**. The size is saved. Changes during recording take effect the next time the pill appears.

## Run from source

Install Xcode with Swift 6.2, then run `bash scripts/run-app.sh`. The script builds and opens a signed app bundle. A Developer ID identity keeps permission grants stable between builds; without one, builds use ad-hoc signing.

Source builds include a native **Settings…** window for General, Writing and Appearance, including per-app tone rules. See [settings](docs/SETTINGS.md). This window is not in the existing alpha.3 ZIP.

Allow Microphone and Accessibility access when macOS asks. The menu has links to those settings and **How to Use Mouthtype**. Fn remapping is enabled by default while Mouthtype runs; it hides the emoji picker and preserves Fn navigation combinations.

The speech model and a small speech detector download on first launch. The detector keeps empty recordings from becoming invented words. Download and loading status appear in the menu; **Retry Speech Model** appears if preparation fails. Transcription runs locally. Parakeet v3 decoding uses an English language hint to prevent accidental Cyrillic output; Whisper also requests English. Smart cleanup is a separate optional model download, with basic cleanup available without it.

Fast cleanup uses S1-mini by Superwhisper locally, a roughly 1.4 GB download. Thorough uses Gemma 4 E4B, a roughly 5.2 GB download. Both handle fillers, corrections and spoken technical notation while preserving wording. Neither mode authorizes paraphrasing or a more formal voice. Cleanup can read up to 300 UTF-16 units before the cursor and 40 after it when available, excluding secure fields. This supports boundary formatting and limited spelling hints; it does not read previous chat messages as conversation history. Fast cleanup receives the current take, and Thorough receives extracted spelling hints. Invalid output or a missed deadline delivers the basic cleanup instead. Known project spellings can be joined in clear software contexts, while ordinary phrases such as a boat in dry dock are preserved. In model-backed cleanup, dictionary entries that only join words are context hints; Basic retains literal dictionary replacements. Ambiguous names still have gaps, especially with Fast cleanup. Neither model is downloaded until requested. Switching models loads the selected cached model and unloads the inactive one after pending work finishes.

Open **Cleanup → Saved Spellings…** to add, edit or delete exact spelling rules. “Heard as” is the word or phrase Mouthtype gets wrong; “Write as” is the spelling you want. Rules match whole words and phrases regardless of capitalization, so use a specific phrase for ambiguous common words. An exact “geoff → Jeff” rule leaves “Geoffrey” alone through model cleanup too. The editor uses the existing local dictionary and learned corrections. It rejects blank or duplicate rules, preserves other entries, and keeps your draft if the file changes outside the editor. **Edit Dictionary…** still opens the file for manual repair. Cleanup Off leaves words unchanged.

Open **Cleanup → Phrase Replacements…** to save a spoken phrase and the exact text to insert. For example, set “my work email” to your email address, then say it alone or inside a sentence. Matching ignores capitalization, uses whole phrases, and picks the longest match. The library starts empty and is stored locally in `~/Library/Application Support/Mouthtype/phrases.json`. Add, edit, or delete phrases in the editor; save or cancel a draft before changing selection. Duplicate triggers are rejected. A malformed file keeps the last good library in use and must be repaired before editing.

Replacements expand after cleanup, so their spelling, capitalization, spaces, and line breaks survive Basic, Fast, Thorough, and every tone. A model that changes the spoken triggers falls back to Basic text. `{date}` inserts the current long date in your locale; `{clipboard}` inserts the clipboard text captured for that dictation, or nothing if no text is available. Inserted text is never expanded again. Punctuation outside the spoken trigger stays outside the replacement. Cleanup Off also turns phrase expansion off.

For a terminal that loses text from large pastes, focus its window and enable **Paste Options → Split Long Pastes in [app]**. This is off by default and saved separately for Terminal, iTerm2, Ghostty, kitty and WezTerm. It applies to all windows of the selected terminal app, including CLI editors such as Claude Code and Codex CLI; it does not detect the program running inside a terminal.

Split pastes preserve the text exactly and never send Return. Each part waits for a clipboard read and a settling delay before the next part. Typing, focus changes, a new clipboard copy, cancellation, an unread part, or the eight-second overall limit stop the paste. A read permits advancing the clipboard; it does not prove insertion. The original clipboard is restored unless you copied something else. An interrupted paste offers the full transcript with Copy and warns that some text may already be there. Check the field before pasting the full copy, to avoid duplicates. Per-app paste shortcut selection and typed delivery are deferred. Per-app cleanup styles are available in source builds under **Settings → Writing**. They aren't included in the existing alpha.3 ZIP.



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

## Website

The Vercel-ready product site lives in [website/](website/README.md), with its own static build and browser checks. It builds independently of the native app.
