# Dictating

How to start, stop and recover a take, and the settings that change how recording behaves.

## Hold to talk or hands-free

By default you **hold** Fn while you speak and release it to finish. That's Hold to talk.

For longer takes, go hands-free. Double-tap Fn, or press Fn+Space, and Mouthtype keeps recording after you let go. Tap Fn to stop. Stop and Cancel also live on the pill and in the menu while a hands-free take is running.

Press **Esc** to cancel a take. You get a five-second Undo window. If Esc is your dictation shortcut, use Cancel from the pill or the menu instead.

A single recording stops on its own after 20 minutes. A "One minute left" card appears at 19.

## Switch to press to toggle

If you'd rather press once to start and once to stop, open **Settings → General → Recording behavior** and choose **Press to toggle**. Releasing the shortcut doesn't stop the take in this mode. Changing the behavior cancels a recording that's in progress.

## Change the shortcut

**Settings → General** has the dictation shortcut. Click Change, press the key or combination you want, release everything, then Save. Cancel or Esc keeps the old one. **Use Fn / Globe** restores the default.

Your shortcut is reserved for Mouthtype while it's running, including a bare letter. Caps Lock always works as press-to-start, press-to-stop, even in Hold mode. Some media and system keys get handled by macOS before Mouthtype sees them.

By default Mouthtype remaps Fn so the Globe key doesn't open the emoji picker. That's **Settings → Advanced → Remap Fn to hide the emoji picker**. It only applies while Mouthtype is running and only when your shortcut is Fn.

## Paste last and copy last

Two global shortcuts work on the latest saved take, even after a restart.

- **Paste Last Take**: Control+Command+V
- **Copy Last Take**: Control+Command+C

Both are in the menu too, and **Recent Takes** lists earlier ones. If your dictation shortcut uses one of those combinations, the dictation shortcut wins and the menu shows no shortcut for that action.

## Choose a microphone

**Settings → General → Microphone** follows System Default unless you pick a specific microphone, which only changes what Mouthtype uses, not your Mac's input. A saved microphone that's unplugged stays selected. Mouthtype won't quietly record from another one. Reconnect it or pick a different input.

There's also an opt-in **Priority list**. Order your microphones and Mouthtype picks the first connected one at the start of each take. System Default fallback is a separate switch. Built-in microphones are the tested path. Bluetooth and USB microphones haven't been verified on a device yet.

## Live words

**Settings → General → Live words** is off by default. Turn it on and provisional words appear above the pill while you speak. They can change or drop earlier words. The finished take still goes through full transcription and is inserted once, and the preview text never goes into your history.

## Recording sounds

Click is the default sound set: a key-down thunk to start, a duller key-up thunk to stop, and matching cues for locking and errors. Turn the cues on or off under **Settings → General → Recording sounds**.

## Quiet other audio

**Quiet other audio** is on by default as of 0.4.0, and stays off if you'd turned it off before. While you record, Mouthtype mutes your Mac's current output and restores it when the take ends, whether you stop, cancel, or the microphone drops. It never touches volume, leaves an already-muted output alone, and skips outputs that have no settable mute. It doesn't pause media players. If Mouthtype crashes mid-take it can't restore, so check your Mac's mute if that happens.

## Spoken commands

Say punctuation, line breaks and lists instead of typing them. That's on by default under **Settings → Advanced**, and it works through the cleanup pass, so Cleanup Off skips it. The full list is in [spoken commands](../SPOKEN-COMMANDS.md).

## When a paste doesn't land

Mouthtype keeps your text when delivery goes wrong.

- If nothing has focus, the card says "Nothing to paste into".
- If the field didn't change after a paste, it says "Paste didn't land" and offers the transcript to copy. Some apps don't report a change even when text arrived, so look at the field before pasting again.
- A secure field, like a password box, gets nothing pasted. The card says "Secure field, not pasted" and keeps the text.
- If the microphone disconnects mid-take, what was captured is saved and you can **Insert** or **Discard** it.
- After a crash or force-quit, the next launch offers "Recover your last dictation?".
- Older interrupted or failed recordings are under **Saved Recordings** in the menu. Recovery pauses new recordings until it finishes.
- Home lists your recent takes. **Copy** puts a take's text on the clipboard, and **Recover** reruns one whose audio is still saved.

More fixes are in [Troubleshooting](../TROUBLESHOOTING.md).
