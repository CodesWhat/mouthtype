# Privacy and data

Mouthtype is built to keep your voice and text on your Mac. This page covers where things live and the few things that touch the network.

## What stays on your Mac

Recognition, cleanup, your history, your dictionary, your settings and your recordings. Automation URLs carry a command and a page name, never text or audio.

## Where the data lives

The data directory is `~/Library/Application Support/Mouthtype`.

| File | Holds |
| --- | --- |
| `mouthtype.sqlite` | Your history. |
| `audio/` | Recordings, next to the database. |
| `dictionary.json` | Your spellings. |
| `phrases.json` | Your transforms. |
| `dismissed-suggestions.json` | Dismissed suggestions. |

> [!WARNING]
> Don't delete the data folder when upgrading. Mouthtype doesn't encrypt its database, recordings or backups.

Uninstalling the app doesn't remove the folder. Quit Mouthtype before you remove it, and delete the data folder only if you mean to erase it.

## Retention

Text history is kept indefinitely. Completed recordings are pruned by the rules under **Settings → Advanced → Storage**.

- Age: 14, 30 or 90 days, or No age limit.
- Size: 2 GB or 10 GB.
- Defaults are 90 days and 2 GB.
- Changes apply at the next launch, to completed recordings only. The text and word timings stay.
- Unfinished recordings, crash-recovery audio and failed takes available for recovery are exempt, so they can use extra space.
- Removed audio can't be restored.

Details are in [saved audio](../AUDIO-RETENTION.md).

Takes from secure fields are never shown and never counted in stats. Audio you import with Transcribe Audio File stays where it is and isn't part of the archive.

## What uses the network

- **Model downloads.** The speech model and detector on first launch, the optional Fast and Thorough cleanup models when you ask, and a roughly 100 MB extra model the first time you turn on Boost saved words (off by default). These need internet access.
- **Update checks.** On by default and switchable in Settings → Mac. They and update downloads go over HTTPS, include no transcripts or recordings, and anonymous system profiling is disabled. Installation is always your choice.

Ordinary request metadata is visible to the hosting providers, like any download.

Transcription, cleanup, Transform Selection and file transcription don't upload your audio or text.

## Secure fields

Mouthtype refuses to paste into secure fields, keeps the text so you can copy it, and cleanup never reads text from them. It doesn't get around macOS Secure Input. See [Troubleshooting](../TROUBLESHOOTING.md).

## More

The [security reference](../SECURITY.md) lists the controls and their limits.
