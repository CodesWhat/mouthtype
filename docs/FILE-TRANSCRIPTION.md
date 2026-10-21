# Transcribe an audio file

Mouthtype can turn one audio file into a raw transcript using the speech model already loaded on your Mac. It doesn't record the microphone or upload your audio.

## Transcribe a file

1. Choose **Transcribe Audio File…** in Mouthtype's menu, or the **Transcribe a file…** button on Home. The window opens even when no Mouthtype window is up.
2. Choose one WAV, AIFF or M4A file.
3. Wait for the status chip to finish. Mouthtype reads and resamples the file in small chunks and shows preparation, transcription and cancellation states.
4. Use **Copy** to put the transcript on the clipboard, or **Save Text…** to write a UTF-8 text file. Neither action runs automatically.

## Limits

| Limit | Value |
| --- | --- |
| Formats | WAV, AIFF, M4A |
| Length | Up to 10 minutes |
| Size | Up to 512 MB |

## What you get

The window shows the file's name, length and size with a status chip, then the full raw transcript with a word count and a RAW · NO CLEANUP tag. The text is selectable. Your original audio is preserved, and Mouthtype refuses to save the transcript over that source file.

## What it doesn't do

- It doesn't apply cleanup, saved spellings or phrase replacements.
- It doesn't paste into another app.
- It doesn't add to recent dictations.
- It doesn't change dictation statistics.

## While it runs

Cancel stops further work when the current recognition operation returns. A file that fails to import leaves the previous transcript on screen and says which file failed.

> [!NOTE]
> Closing the Transcribe Audio File window also cancels a running import. Closing or switching the Mouthtype window does not; the transcript is there when you reopen it.

Dictation, saved-recording recovery and update installation wait until file transcription has finished or cancellation has settled. Finish any dictation or recovery before importing a file.
