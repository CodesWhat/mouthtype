# Troubleshooting

Fixes for the problems people hit most, grouped by what you see.

## Start here

Start with **Settings → Health**. It shows model status, Microphone and Accessibility state, shortcut health and the Globe key check, and has a button for each repair. When something needs attention, the menu shows a line such as "Accessibility access needed…" and clicking it opens Health. **Refresh status** at the bottom re-reads everything.

See [known limits](KNOWN-LIMITS.md) for what hasn't been verified. Install steps are in the [install notes](READ-ME.md).

| Symptom | Section |
| --- | --- |
| Permission prompts or Health says "not allowed" | [Microphone or Accessibility isn't allowed](#microphone-or-accessibility-isnt-allowed) |
| Fn does nothing, or the emoji picker opens | [Fn doesn't start dictation, or the emoji picker opens](#fn-doesnt-start-dictation-or-the-emoji-picker-opens) |
| "Dictation is paused by Secure Input…" | [Dictation is paused by Secure Input](#dictation-is-paused-by-secure-input) |
| Model won't load, or a download stalls | [The speech model won't load, or a download stalls](#the-speech-model-wont-load-or-a-download-stalls) |
| No text, or text in the wrong place | [Text didn't appear, or appeared in the wrong place](#text-didnt-appear-or-appeared-in-the-wrong-place) |
| A take was interrupted or lost | [Recovering a take](#recovering-a-take) |
| Updates don't show up | [Update checks](#update-checks) |
| Glass is hard to read, or motion looks off | [Pill and card looks](#pill-and-card-looks) |

## Microphone or Accessibility isn't allowed

Likely cause: Mouthtype needs both permissions. Microphone records your voice. Accessibility lets the shortcut work and puts text into the app you're using.

1. Health shows "Microphone: not allowed" or "Accessibility: needed". Use **Microphone Settings…** or **Accessibility Settings…** next to it, turn Mouthtype on in System Settings → Privacy & Security, then come back to the app.
2. macOS asks for Microphone when you first record. The Accessibility prompt appears once; after that, use the Health button or the menu line, because Mouthtype won't prompt again.
3. Mouthtype checks Accessibility about once a second, so the shortcut starts working shortly after you grant it. You don't need to relaunch. If the status stays "needed", remove Mouthtype from the Accessibility list, add it again and turn it on.
4. If you deferred setup, reopen it with **Set Up Mouthtype…** in Settings > Health. Setup also opens by itself at launch when either permission is missing.

Replacing the app with a build signed differently can invalidate an old grant.

## Fn doesn't start dictation, or the emoji picker opens

Likely cause: macOS still sees Fn. By default Mouthtype remaps Fn so the Globe key doesn't open the emoji picker. That remap is **Settings → Advanced → Remap Fn to hide the emoji picker**.

- If the toggle is off, or you use a custom shortcut, macOS still sees Fn. Settings > Health shows a Globe key row ("Globe key opens Emoji & Symbols", "Globe key changes input source" or "Globe key starts Dictation") with a **Keyboard Settings…** button. Either turn the remap on, or set the Globe key action to Do Nothing in System Settings → Keyboard.
- The remap only applies while Mouthtype is running, and only when your shortcut is Fn / Globe. A custom shortcut leaves Fn alone, and the toggle is disabled with a note saying so.
- If dictation does nothing at all, check Health for "Dictation input is off…" or "recovering". "Off" usually means Accessibility isn't granted. "Recovering" clears by itself once the shortcut listener restarts.
- If saving a shortcut fails with "The input listener could not start", check Accessibility, then try again. Your previous shortcut stays saved.
- Keyboards without a Fn/Globe key (some third-party ones) can't use the default. Pick another shortcut under Settings → General.

## Dictation is paused by Secure Input

Likely cause: a password field has focus, or an app left Secure Input on.

> [!NOTE]
> macOS turns on Secure Input while a password field has focus, and some apps leave it on. Mouthtype doesn't bypass it.

Settings > Health shows "Hotkey: secure input on" and the menu says "Dictation is paused by Secure Input…". Leave the password field, or quit the app that's holding it, and dictation resumes.

If you start a take and the focus lands in a secure field before it ends, the text isn't pasted. The card says "Secure field, not pasted" and keeps the text so you can copy it. Cleanup also never reads text from secure fields.

## The speech model won't load, or a download stalls

Likely cause: the download needs internet access, or the model is still loading. Dictating right after launch can find the speech model still loading, so wait for the status to read ready.

- Speech model status is in **Settings → Health** under Local models. If it failed, click **Retry model**. The menu has **Retry Speech Model** too. Downloads need internet access.
- The optional cleanup models (Fast, about 1.4 GB; Thorough, about 5.2 GB) download only when you ask. On the Style page (Cleanup tab) or in Settings > Health, choose **Download…**, confirm, and watch the percentage. **Cancel download** stops it.
- Until the chosen cleanup model is ready, dictations use Basic cleanup. That's expected, not an error.
- A failed or incomplete cleanup download shows the error in Settings > Health and a **Download…** button. Clicking it repairs an incomplete cache.

## Text didn't appear, or appeared in the wrong place

Likely cause: no text field had focus, or the app didn't report the paste.

- Make sure a text field has focus. With nowhere to paste, the card says "Nothing to paste into" and keeps the text.
- If the field didn't change after a paste, the card says "Paste didn't land" and offers the transcript to copy. Some apps don't report a change even when text arrived, so look at the field before pasting again.
- If a take you held for a second or more produced nothing, the card says "Microphone heard nothing" (no sound at all) or "No speech heard" (sound but no speech) and names the microphone that was recording. **Sound settings** opens the input list. **Try a test take** on Setup's last card (**Settings > Health > Set Up Mouthtype**) checks the microphone without pasting.
- **Paste Last Take** (<kbd>Control</kbd>+<kbd>Command</kbd>+<kbd>V</kbd>) and **Copy Last Take** (<kbd>Control</kbd>+<kbd>Command</kbd>+<kbd>C</kbd>) work on the latest saved take, even after a restart. **Recent Takes** in the menu lists earlier ones.

> [!WARNING]
> Long pastes into a terminal can lose text. Turn on split pastes for that app under Settings > Advanced > Delivery. If a split paste is interrupted, some text may already be there. Check the field before copying the full text.

## Recovering a take

Likely cause: the microphone disconnected, Mouthtype crashed or was force-quit, or a recording was interrupted.

- If the microphone disconnects mid-recording, what was captured is saved and the card offers **Insert** or **Discard**.
- After a crash or force-quit, the next launch offers "Recover your last dictation?". Recovery pauses new recordings until it finishes.
- Older interrupted or failed recordings are under **Saved Recordings** in the menu. Open it to load the list (20 per page), then choose one to recover. If it fails, the card says "Couldn't recover", the audio is kept, and you can try again. "Saved recordings unavailable" means the list couldn't be read.
- <kbd>Esc</kbd> cancels a take and offers Undo for five seconds.
- Saved audio follows the retention you chose (default 90 days and 2 GB). Unfinished and recovery audio isn't pruned.

## Update checks

Likely cause: checks are off, or an install is waiting for a task to finish.

- Use **Check for Updates…** in the menu. When one is found, **Update Available…** also appears at the top of the menu.
- Automatic checks are on by default. Turn them off with **Check for updates automatically** in Settings → Mac.
- Updates wait while a dictation, recovery or file transcription is running.
- Checks go over HTTPS and don't send transcripts or recordings.

> [!NOTE]
> Alpha.1 to alpha.3 have no updater. Download the current build from the website once.

## Pill and card looks

Likely cause: a macOS accessibility setting changes how the pill and cards draw.

- Under macOS **Reduce Transparency** (System Settings → Accessibility → Display), the Glass style uses a solid background, and the Appearance preview says "Glass · solid: Reduce Transparency".
- Under **Reduce Motion**, the pill and cards use shorter fades instead of springs and slides, long pill text is held and then jumps to its end rather than scrolling, and the menu bar icon stays on its middle frame.
- If Glass is hard to read on your wallpaper, switch Pill style on the Appearance page. A non-Glass style doesn't depend on what's behind it.

## Still stuck

Send these, and share transcripts or audio only if you choose to.

- [ ] The version and macOS version.
- [ ] The destination app.
- [ ] What you said, what appeared and any warning.
- [ ] Whether the text appeared once, twice or not at all.
