# Linux

Linux support is experimental and source-only. There's no supported Linux desktop release.

## What exists

The source includes a daemon and CLI aimed at Linux x86_64 on Arch or Omarchy, with Hyprland and PipeWire. The first target has had component checks, but physical Arch/Omarchy acceptance is still open. Container and headless checks don't establish microphone or Hyprland support.

- Delivery is recovery-only by default, with no clipboard or key changes. Automatic typing and paste are explicit opt-ins.
- Cleanup is off by default. Basic is deterministic. Fast and Thorough run local models on the CPU after an explicit prepare step. Thorough is Qwen3 4B here, not the Mac model.
- It supports saved spellings, phrases, and single-file audio transcription of one WAV, AIFF or M4A with your distro's `ffmpeg`.
- There are no live word previews, secure-field detection or insertion verification.

## Where to start

The source archive is at [mouthtype.app/source](https://mouthtype.app/source). It includes the guides below, which are also copied into these docs.

- [Linux desktop setup and testing](linux-desktop-setup.md) is `tools/linux-desktop/README.md`.
- [Omarchy plugin](linux-omarchy-plugin.md) is `tools/omarchy-plugin/README.md`. It adds a bar menu, a floating pill and a choice of toggle or hold shortcut. Its installer enables a login service unless you pass `--no-autostart`.
- An ordered install checklist for people and coding agents is at [mouthtype.app/linux/agent-install.md](https://mouthtype.app/linux/agent-install.md).

The speech-preparation helper downloads pinned model files, verifies their hashes and builds a dedicated environment. It doesn't record, register shortcuts or start a service.
