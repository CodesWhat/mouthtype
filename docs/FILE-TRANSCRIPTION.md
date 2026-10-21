# Transcribe an audio file

Choose **Transcribe Audio File…** in Mouthtype's menu, which opens the Transcribe Audio File window (it opens even when no Mouthtype window is up, and so does the **Transcribe a file…** button on Home), then choose one WAV, AIFF or M4A file. Files can be up to 10 minutes long and 512 MB. Speech recognition uses the model already loaded on your Mac. It doesn't record the microphone or upload your audio.

Mouthtype reads and resamples the file in small chunks. It shows preparation, transcription and cancellation states. Cancel stops further work when the current recognition operation returns. Closing the Transcribe Audio File window also cancels a running import. Closing or switching the Mouthtype window does not; the transcript is there when you reopen it. A file that fails to import leaves the previous transcript on screen and says which file failed.

The window shows the file's name, length and size with a status chip, then the full raw transcript with a word count and a RAW · NO CLEANUP tag. The text is selectable. Use **Copy** to put it on the clipboard, or **Save Text…** to write a UTF-8 text file. Neither action runs automatically. Your original audio is preserved, and Mouthtype refuses to save the transcript over that source file.

File transcription doesn't apply cleanup, saved spellings or phrase replacements. It doesn't paste into another app, add to recent dictations, or change dictation statistics. Dictation, saved-recording recovery and update installation wait until file transcription has finished or cancellation has settled. Finish any dictation or recovery before importing a file.
