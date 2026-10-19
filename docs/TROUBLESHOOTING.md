# Troubleshooting

Start with **Settings → Diagnostics**. It shows model status, Microphone and Accessibility state, shortcut health and the Globe key check, and has a button for each repair. When something needs attention, the menu shows a line such as "Accessibility access needed…" and clicking it opens Diagnostics. **Refresh status** at the bottom re-reads everything.

See [known limits](KNOWN-LIMITS.md) for what hasn't been verified. Install steps are in the [install notes](READ-ME.md).

## Microphone or Accessibility isn't allowed

Mouthtype needs both. Microphone records your voice. Accessibility lets the shortcut work and puts text into the app you're using.

- Diagnostics shows "Microphone: not allowed" or "Accessibility: needed". Use **Microphone Settings…** or **Accessibility Settings…** next to it, turn Mouthtype on in System Settings → Privacy & Security, then come back to the app.
- macOS asks for Microphone when you first record. The Accessibility prompt appears once; after that, use the Diagnostics button or the menu line, because Mouthtype won't prompt again.
- Mouthtype checks Accessibility about once a second, so the shortcut starts working shortly after you grant it. You don't need to relaunch. If the status stays "needed", remove Mouthtype from the Accessibility list, add it again and turn it on. Replacing the app with a build signed differently can invalidate an old grant.
- If you deferred setup, reopen it with **Set Up Mouthtype…** in the Settings sidebar. Setup also opens by itself at launch when either permission is missing.

## Fn doesn't start dictation, or the emoji picker opens

By default Mouthtype remaps Fn so the Globe key doesn't open the emoji picker. That remap is **Settings → Diagnostics → Remap Fn to hide the emoji picker**.

- If the toggle is off, or you use a custom shortcut, macOS still sees Fn. Diagnostics shows a Globe key row ("Globe key opens Emoji & Symbols", "Globe key changes input source" or "Globe key starts Dictation") with a **Keyboard Settings…** button. Either turn the remap on, or set the Globe key action to Do Nothing in System Settings → Keyboard.
- The remap only applies while Mouthtype is running, and only when your shortcut is Fn / Globe. A custom shortcut leaves Fn alone, and the toggle is disabled with a note saying so.
- If dictation does nothing at all, check Diagnostics for "Dictation input is off…" or "recovering". "Off" usually means Accessibility isn't granted. "Recovering" clears by itself once the shortcut listener restarts.
- If saving a shortcut fails with "The input listener could not start", check Accessibility, then try again. Your previous shortcut stays saved.
- Keyboards without a Fn/Globe key (some third-party ones) can't use the default. Pick another shortcut under Settings → General.

## Dictation is paused by Secure Input

macOS turns on Secure Input while a password field has focus, and some apps leave it on. Mouthtype doesn't bypass it. Diagnostics shows "Hotkey: secure input on" and the menu says "Dictation is paused by Secure Input…". Leave the password field, or quit the app that's holding it, and dictation resumes.

If you start a take and the focus lands in a secure field before it ends, the text isn't pasted. The card says "Secure field, not pasted" and keeps the text so you can copy it. Cleanup also never reads text from secure fields.

## The speech model won't load, or a download stalls

- Speech model status is in **Settings → Diagnostics** under Local models. If it failed, click **Retry model**. The menu has **Retry Speech Model** too. Downloads need internet access.
- The optional cleanup models (Fast, about 1.4 GB; Thorough, about 5.2 GB) download only when you ask. In Diagnostics or General, choose **Download…**, confirm, and watch the percentage. **Cancel download** stops it.
- Until the chosen cleanup model is ready, dictations use Basic cleanup. That's expected, not an error.
- A failed or incomplete cleanup download shows the error in Diagnostics and a **Download…** button. Clicking it repairs an incomplete cache.
- Dictating right after launch can find the speech model still loading. Wait for the status to read ready.

## Text didn't appear, or appeared in the wrong place

- Make sure a text field has focus. With nowhere to paste, the card says "Nothing to paste into" and keeps the text.
- If the field didn't change after a paste, the card says "Paste didn't land" and offers the transcript to copy. Some apps don't report a change even when text arrived, so look at the field before pasting again.
- **Paste Last** (Control+Command+V) and **Copy Last** (Control+Command+C) work on the latest saved take, even after a restart. **Recent Dictations** in the menu lists earlier ones.
- Long pastes into a terminal can lose text. Turn on split pastes for that app under Settings → Writing → Delivery. If a split paste is interrupted, some text may already be there. Check the field before copying the full text.

## Recovering a take

- If the microphone disconnects mid-recording, what was captured is saved and the card offers **Insert** or **Discard**.
- After a crash or force-quit, the next launch offers "Recover your last dictation?". Recovery pauses new recordings until it finishes.
- Older interrupted or failed recordings are under **Saved Recordings** in the menu. Open it to load the list (20 per page), then choose one to recover. If it fails, the card says "Couldn't recover", the audio is kept, and you can try again. "Saved recordings unavailable" means the list couldn't be read.
- Escape cancels a take and offers Undo for five seconds.
- Saved audio follows the retention you chose (default 90 days and 2 GB). Unfinished and recovery audio isn't pruned.

## Update checks

- Use **Check for Updates…** in the menu. When one is found the item reads **Update Available…**.
- Automatic checks are on by default. Turn them off with **Check automatically** in Settings → General.
- Updates wait while a dictation, recovery or file transcription is running.
- Alpha.1 to alpha.3 have no updater. Download the current build from the website once.
- Checks go over HTTPS and don't send transcripts or recordings.

## Pill and card looks

- Under macOS **Reduce Transparency** (System Settings → Accessibility → Display), the Glass style uses a solid background, and the Appearance preview says "Glass · solid: Reduce Transparency".
- Under **Reduce Motion**, the pill and cards use shorter fades instead of springs and slides, long pill text is held and then jumps to its end rather than scrolling, and the menu bar icon stays on its middle frame.
- If Glass is hard to read on your wallpaper, switch Pill style under Settings → Appearance. a non-Glass style doesn't depend on what's behind it.

## Still stuck

Send the version, macOS version, destination app, what you said, what appeared and any warning. Say whether the text appeared once, twice or not at all. Only share transcripts or audio you choose to.
