<div align="center">

<img src="website/public/assets/mouthtype-icon.png" alt="Mouthtype app icon" width="112">

# Mouthtype

**Local dictation for your Mac. Hold Fn, speak, release to paste.**

Natural speech in, clean text out.

[Download the Mac release candidate](https://mouthtype.app/download) · [Getting started](https://mouthtype.app/start/) · [Documentation](https://mouthtype.app/docs/) · [Security](SECURITY.md)

</div>

Mouthtype runs speech recognition and cleanup on your Mac. It puts the result in the text field you're already using, with local history and recovery when delivery fails. No account or transcription subscription is required.

The Mac app is at 0.1.0-rc.3, a release candidate. It supports **Apple Silicon and macOS 26 or later**. The repository remains private; the signed app and corresponding release source are available without repository access.

## Install

1. Download the signed, notarized ZIP from [mouthtype.app/download](https://mouthtype.app/download).
2. Extract Mouthtype, move it to Applications and open it.
3. Grant Microphone and Accessibility access when prompted. The speech model and a small speech detector download on first launch.
4. Click an ordinary text field, hold **Fn**, speak, then release.

Existing alpha.1–3 installations need one manual download to get the built-in updater. Builds after alpha.3 offer **Check for Updates…** and optional automatic checking. See the [install and upgrade notes](docs/READ-ME.md) before replacing an existing app.

## What it does

| Feature | Behavior |
| --- | --- |
| Hold or hands-free dictation | Hold Fn, double-tap Fn, or use Fn+Space. Recording behavior and shortcuts are configurable. |
| Local cleanup | Basic formatting works without a cleanup model. Fast (the default level) and Thorough use optional local models and preserve wording. Until the selected model finishes downloading, dictations use Basic. |
| Writing rules | Choose Formal, Casual or Very casual, with per-app and website tone rules. |
| Saved spellings and phrases | Keep exact local spelling rules and reusable text, including multiline phrases. |
| Microphone selection | Follow System Default, choose a named input, or opt into an ordered priority list. |
| Recovery | Copy or retry saved text after a failed paste. Interrupted audio remains recoverable. |
| Clean Selected Text | Choose **Clean Selected Text…** to preview Basic cleanup on text you've selected in another app, then explicitly accept the replacement. |
| File transcription | Import one WAV, AIFF or M4A, up to 10 minutes and 512 MB, then explicitly copy or save the result. |

<p align="center">
  <img src="website/public/assets/classic-recording.png" alt="Mouthtype's Classic recording pill showing an active take" width="400">
</p>

See [the usage reference](docs/USAGE.md) for cleanup behavior, delivery limits and current prerelease caveats. **Quiet other audio** and **Live words** are optional and off by default. Check the destination before retrying an interrupted paste, since some text may already have arrived. A single recording stops after 20 minutes, with a warning at 19. **Control+Command+V** pastes the last delivered take and **Control+Command+C** copies it. Split pastes preserve text and never synthesize a Return key press.

## Privacy and permissions

Audio, transcripts, settings, spellings and phrases stay on this Mac. The default data directory is `~/Library/Application Support/Mouthtype/`. Text history is retained indefinitely. Completed audio defaults to 90 days and 2 GB; unfinished and recovery audio are protected from normal retention cleanup. The local database and recordings aren't encrypted by Mouthtype, so protect the Mac and its backups accordingly.

Microphone access records a take. Accessibility access handles the global shortcut, examines the destination and inserts text. Cleanup can read a small amount of nearby text for formatting and spelling hints, excluding secure fields. Phrase rules can explicitly insert the clipboard's text. These are powerful permissions; grant them only to a build you trust.

Model downloads and optional update checks use the network. Dictation and cleanup run locally. The [security policy](SECURITY.md) and [security controls and limits](docs/SECURITY.md) describe reporting, distribution integrity and the boundaries of those claims.

## Documentation

- [Install, update and remove](docs/READ-ME.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Known limits for 0.1.0](docs/KNOWN-LIMITS.md)
- [Settings, tone rules and input selection](docs/SETTINGS.md)
- [Usage and cleanup reference](docs/USAGE.md)
- [Spoken commands and counted lists](docs/SPOKEN-COMMANDS.md)
- [Saved audio and retention](docs/AUDIO-RETENTION.md)
- [File transcription](docs/FILE-TRANSCRIPTION.md)
- [Website development](website/README.md)
- [Release procedure](docs/RELEASING.md)

## Build and contribute

Install Xcode with Swift 6.2 on a supported Mac. Run `bash scripts/run-app.sh` to build and open a signed app bundle. Without a Developer ID identity, the script uses ad-hoc signing; permission grants and distribution guarantees differ from the released app.

Run `swift test` for core, macOS integration logic, Settings rendering and Fn guardian tests. Desktop self-tests take focus and require a free desktop. Tests don't replace physical microphone or third-party app acceptance.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for checks, dependency maintenance and the reviewed development-branch workflow. Bug reports from repository collaborators belong in private issues. Include the app version, macOS version, destination app and reproduction steps; omit personal transcripts and recordings. Report vulnerabilities through [SECURITY.md](SECURITY.md).

## Experimental Linux source

Linux work targets x86_64 Arch/Omarchy, Hyprland and PipeWire. The source includes a daemon/CLI, setup diagnostics, an Omarchy bar plugin with a floating pill, single-file audio transcription, optional paste or typing delivery and optional local Fast and Thorough cleanup models. Delivery is recovery-only and cleanup is off by default. **There is no supported Linux desktop release.** Physical acceptance remains open, and the Linux cleanup models differ from the Mac ones (Thorough is Qwen3 4B, not Gemma). Follow the [Linux setup and testing guide](tools/linux-desktop/README.md) or the [Omarchy plugin guide](tools/omarchy-plugin/README.md). Coding agents can follow the ordered checklist at [mouthtype.app/linux/agent-install.md](website/public/linux/agent-install.md).

## License

Mouthtype is licensed under [GPL-3.0](LICENSE). [Corresponding release source](https://mouthtype.app/source) is available separately from the app download. Dependencies, fonts, adapted code and downloaded models have their own terms. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) records adapted code, fonts and the S1-mini model; Swift package dependencies carry their own licenses in their upstream repositories.
