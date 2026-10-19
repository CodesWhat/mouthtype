# Mouthtype

Local dictation for Apple Silicon Macs running macOS 26 or later.

Click a text field, hold Fn and speak, then release to paste. Double-tap Fn or press Fn+Space for hands-free dictation; tap Fn to stop. Esc cancels, with a five-second Undo window.

## Mac release candidate

The latest published release, 0.1.0-rc.3, supports Apple Silicon Macs on macOS 26 or later. Download the signed, notarized ZIP from [mouthtype.app](https://mouthtype.app/download) and follow [the install notes](READ-ME.md). Repository access is not required. [Corresponding release source](https://mouthtype.app/source) is available separately. Existing alpha.1–3 users need this download once to get the built-in updater.

For a larger pill in any style, choose **Settings → Appearance → Pill size → Large**. Automatic, the default, picks Large on screens at least 2000 pt wide. The size is saved. Changes during recording take effect the next time the pill appears.

## Run from source

Install Xcode with Swift 6.2, then run `bash scripts/run-app.sh`. The script builds and opens a signed app bundle. A Developer ID identity keeps permission grants stable between builds; without one, builds use ad-hoc signing.

The app includes a native **Settings…** window with General, Writing, Appearance and Diagnostics panes, including per-app tone rules. See [settings](SETTINGS.md). General also has update-check preferences; the menu offers **Check for Updates…**. Updates are signed and wait for dictation, recovery and file transcription to finish.

**Settings → General → Recording behavior** offers **Hold to talk** (the default) or **Press to toggle**. Toggle starts recording with one press and stops with the next; releasing the shortcut keeps recording. This preserves your chosen key or combination. Escape cancels, except when Escape itself is your dictation key; use the pill or menu to cancel then.

Allow Microphone and Accessibility access when macOS asks. Settings → Diagnostics has permission repair links; the menu also has **How to Use Mouthtype**. Fn remapping is enabled by default while Mouthtype runs; it hides the emoji picker and preserves Fn navigation combinations.

The speech model and a small speech detector download on first launch. The detector keeps empty recordings from becoming invented words. Download and loading status are in Settings → Diagnostics; an attention item in the menu opens it when preparation fails. Transcription runs locally. Parakeet v3 decoding uses an English language hint to prevent accidental Cyrillic output; Whisper also requests English. Smart cleanup is a separate optional model download, with basic cleanup available without it.

Fast cleanup uses S1-mini by Superwhisper locally, a roughly 1.4 GB download. Thorough uses Gemma 4 E4B, a roughly 5.2 GB download. The default level is Fast; dictations use Basic until its model finishes downloading. Both handle fillers, corrections and spoken technical notation while preserving wording. Neither mode authorizes paraphrasing or a more formal voice. Cleanup can read up to 300 UTF-16 units before the cursor and 40 after it when available, excluding secure fields. This supports boundary formatting and limited spelling hints; it does not read previous chat messages as conversation history. Fast cleanup receives the current take, and Thorough receives extracted spelling hints. Invalid output or a missed deadline delivers the basic cleanup instead. Known project spellings can be joined in clear software contexts, while ordinary phrases such as a boat in dry dock are preserved. In model-backed cleanup, dictionary entries that only join words are context hints; Basic retains literal dictionary replacements. Ambiguous names still have gaps, especially with Fast cleanup. Neither model is downloaded until requested. Switching models loads the selected cached model and unloads the inactive one after pending work finishes.

Open **Saved spellings…** in the Settings sidebar to add, edit or delete exact spelling rules. “Heard as” is the word or phrase Mouthtype gets wrong; “Write as” is the spelling you want. Rules match whole words and phrases regardless of capitalization, so use a specific phrase for ambiguous common words. An exact “geoff → Jeff” rule leaves “Geoffrey” alone through model cleanup too. The editor uses the existing local dictionary and learned corrections. It rejects blank or duplicate rules, preserves other entries, and keeps your draft if the file changes outside the editor. **Edit dictionary file…** under Settings → Writing → Advanced writing still opens the file for manual repair. Cleanup Off leaves words unchanged.

Open **Phrases…** in the Settings sidebar to save a spoken phrase and the exact text to insert. For example, set “my work email” to your email address, then say it alone or inside a sentence. Matching ignores capitalization, uses whole phrases, and picks the longest match. The library starts empty and is stored locally in `~/Library/Application Support/Mouthtype/phrases.json`. Add, edit, or delete phrases in the editor; save or cancel a draft before changing selection. Duplicate triggers are rejected. A malformed file keeps the last good library in use and must be repaired before editing.

Replacements expand after cleanup, so their spelling, capitalization, spaces, and line breaks survive Basic, Fast, Thorough, and every tone. A model that changes the spoken triggers falls back to Basic text. `{date}` inserts the current long date in your locale; `{clipboard}` inserts the clipboard text captured for that dictation, or nothing if no text is available. Inserted text is never expanded again. Punctuation outside the spoken trigger stays outside the replacement. Cleanup Off also turns phrase expansion off.

For a terminal that loses text from large pastes, open **Settings → General → Advanced delivery** and enable split long pastes for that app. This is off by default and saved separately for Terminal, iTerm2, Ghostty, kitty and WezTerm. It applies to all windows of the selected terminal app, including CLI editors such as Claude Code and Codex CLI; it does not detect the program running inside a terminal.

Split pastes preserve the text exactly and never send Return. Each part waits for a clipboard read and a settling delay before the next part. Typing, focus changes, a new clipboard copy, cancellation, an unread part, or the eight-second overall limit stop the paste. A read permits advancing the clipboard; it does not prove insertion. The original clipboard is restored unless you copied something else. An interrupted paste offers the full transcript with Copy and warns that some text may already be there. Check the field before pasting the full copy, to avoid duplicates. Per-app paste shortcut selection and typed delivery are deferred. Per-app cleanup styles are available under **Settings → Writing**. Rules start empty and preserve the global fallback.

RC.1 also waits for the preceding ordinary paste’s clipboard read before replacing its text. A missing read leaves the next take recoverable instead of overwriting the unread clipboard. A newer user copy remains untouched. Normal Quit first preserves active and queued capture audio, then settles the clipboard change Mouthtype still owns. If preservation fails, the app stays open for a Quit retry. Shutdown blocks late transcription delivery. These checks do not prove that the destination inserted the text; inspect the field before retrying.



## Choose cleanup strength and writing style

Open **Settings → General → Cleanup** to choose the cleanup path: Off keeps the recognized text, Basic applies local formatting rules, Fast adds S1-mini and Thorough uses Gemma. Both model modes preserve wording; they differ in speed and model capability, independently of Tone. Existing saved Light settings become Fast, and Medium becomes Thorough; Off, Basic and tone settings stay as saved.

**Tone** is a separate writing-style choice. **Formal** keeps sentence capitalization and punctuation. **Casual** keeps sentence capitalization and drops the final full stop. **Very Casual** also relaxes sentence capitalization while protecting names and technical spellings. Questions still keep their question marks. These presets don't add enthusiasm or rewrite your personality.

## Microphone, live words and files

**Settings → General → Microphone** follows System Default or remembers a named input for Mouthtype. A missing chosen microphone is reported instead of silently using another input. The choice applies to the next take and does not change the Mac’s system input.

**Quiet other audio** and **Live words** are optional and off by default. Quieting mutes supported output while recording and restores the state Mouthtype still owns. Live words shows provisional text above the pill. Preview text can change; the completed take is still transcribed and inserted once. See [Settings](SETTINGS.md) for hardware and execution limits.

Choose **Transcribe Audio File…** from the menu to import one WAV, AIFF or M4A up to 10 minutes and 512 MB. The full raw result is selectable, with explicit Copy and Save Text. It preserves the original and does not paste, run cleanup or change dictation statistics. See [file transcription](FILE-TRANSCRIPTION.md).

## Experimental Linux source

The source includes a daemon/CLI targeting Linux x86_64, Arch/Omarchy, Hyprland and PipeWire. Its explicit speech-preparation helper verifies pinned model files and creates a dedicated runtime environment. It defaults to recovery-only delivery, with no clipboard or key changes. There is no supported desktop release; physical Arch/Omarchy acceptance remains open. Follow [the Linux setup and testing guide](../tools/linux-desktop/README.md). The [Omarchy plugin](../tools/omarchy-plugin/README.md) adds a bar menu, a floating pill and dictation shortcut choice (toggle or hold), and its installer enables a login service unless you pass `--no-autostart`. The client supports optional saved spellings, phrase replacements and cleanup. Cleanup defaults off and preserves raw results for recovery. Basic is deterministic. Fast (S1-mini) and Thorough (Qwen3 4B) run local llama.cpp models on the CPU after an explicit prepare step, and the Basic text is kept when a model is too slow or changes the meaning. The `paste` delivery mode puts the text on the clipboard, sends Ctrl+V (Ctrl+Shift+V in terminals) and restores the earlier text clipboard; multiline text is refused for terminals. Automatic typing refuses multiline/control-bearing results rather than sending Return or Tab. `mouthtype-linux import` or the plugin menu transcribes one WAV, AIFF or M4A file of up to 10 minutes and 512 MB with the distro `ffmpeg`, and returns the raw result without cleanup. There is a local Arch test-package builder. Linux has no live word previews, secure-field detection or insertion verification. The ordered install checklist is at [mouthtype.app/linux/agent-install.md](../website/public/linux/agent-install.md).

## Recovery and sound

A single recording stops after 20 minutes; a "One minute left" card appears at 19. If the field doesn't change after a paste, Mouthtype shows "Paste didn't land" with the transcript to copy. Secure fields and "Nothing to paste into" also keep the text for copying. If the microphone disconnects mid-recording, what was captured is saved and you can Insert or Discard it. When you correct a dictated word, Mouthtype can offer "Remember this spelling?"; **Learn from my corrections** in Advanced writing turns that off.

If a paste fails or there's nowhere to paste, the result stays available to copy. **Paste Last** and **Copy Last** restore the latest saved transcript after restart. Control+Command+V and Control+Command+C are their global shortcuts, unless your dictation shortcut uses the same combination. The menu also lists recent transcripts.

A recording interrupted by a crash can be recovered on the next launch. **Saved Recordings** makes older interrupted or failed recordings available to recover without pasting into the wrong app. Failed recovery keeps a Recover action so it can be retried. Recovery pauses new recordings until it finishes.

Click is the default sound set: a bright key-down thunk to start, a duller key-up thunk to stop, and matching lock and error cues. **Settings → General → Recording sounds** turns cues on or off. Other sound sets and a picker are deferred.

## Data

History, settings, dictionary and audio stay on this Mac. The default store is `~/Library/Application Support/Mouthtype/mouthtype.sqlite`; recordings are in its sibling `audio` directory. Text history is retained indefinitely. **Settings → General → Saved audio** offers 14, 30 or 90 days, or No age limit, and a 2 GB or 10 GB size limit. Defaults stay 90 days and 2 GB. The next launch prunes only completed Mouthtype recordings; unfinished and recovery audio are protected, and text and timings stay. See [saved audio](AUDIO-RETENTION.md). Model downloads require network access.

Run `swift test` to check the core, macOS integration logic and Fn guardian. The bundled app also has isolated paste and recovery self-tests, which take desktop focus and should be run only when the desktop is free. Those tests restrict keyboard events to their own process and refuse delivery when another app has focus. Live microphone quality and behavior in individual third-party apps still need their own checks.

## Website

The Vercel-ready product site lives in [website/](../website/README.md), with its own static build and browser checks. It builds independently of the native app.
