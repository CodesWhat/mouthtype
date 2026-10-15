# Mouthtype 0.1.0-alpha.1

Private alpha for Apple Silicon Macs running macOS 26 or later. This is an early test build; recognition and behavior in individual apps still need feedback.

## Install

1. Download `Mouthtype-0.1.0-alpha.1-macos-arm64.zip` from the private GitHub release and expand it in Finder.
2. Drag Mouthtype.app into Applications. Quit an older running Mouthtype before replacing it. Keep the included license and these notes for reference.
3. Open Mouthtype from Applications. This distribution is Developer ID signed and notarized. If macOS rejects it, record the exact message and stop; do not disable Gatekeeper.
4. Allow Microphone access when prompted. Use Mouthtype’s menu link to grant Accessibility in System Settings. Return to the app and follow any retry guidance.
5. Wait for the speech model to download and prepare. Network access is needed for downloads; transcription and cleanup run on your Mac. Basic cleanup works without a cleanup-model download. Optional Fast is roughly 1.4 GB; Thorough is roughly 5.2 GB.
6. Click a blank TextEdit document. Hold Fn, say a sentence, then release. Wait for text to appear. Dictate another sentence without clicking or typing between takes. Confirm one insertion per take and a space between them.

Double-tap Fn, or press Fn+Space, for hands-free recording; tap Fn to stop. Escape cancels and offers Undo for five seconds. Control+Command+V pastes the last delivered take. Fn remapping is enabled while the app runs; its menu has a toggle.

## What has been checked

The automated suite has 1,127 passing tests. Physical native checks covered microphone dictation, consecutive-take spacing, Paste Last, Escape without a late insertion, and force-quit recovery through Recover then Copy without automatic pasting. Scott also completed a four-take stop/resume sequence in Orca with each take present once and boundary spaces. Unknown delivery status in an app is not proof that text failed to land.

## Known limitations

- Names and context-dependent recognition can be wrong. A real example was testing recognized as dusting across separate takes. Check text before sending; this alpha does not read previous chat messages to resolve it.
- Broader browser/terminal/Electron behavior, clipboard restoration, physical microphone removal, silence, stop-cue counts and explicit Undo need more live coverage. Orca’s false-failure warning behavior is not fully verified.
- Tone and cleanup Level are separate but global. Casual tone drops the final period on a short take. Per-app cleanup styles and Linux support are not implemented.
- Long terminal paste splitting is off by default. If enabled for a terminal, an interrupted paste may already have inserted some text. Inspect the field before copying the full recovery text to avoid duplication. No Return is sent automatically.
- A fresh installation and model-download flow on a second Mac still need tester confirmation. Existing development-machine permission grants and caches do not verify that path.

## Local data and removal

History, dictionary, settings and recordings stay on your Mac. Text history is retained indefinitely; audio defaults to 90 days or 2 GB. The data directory is `~/Library/Application Support/Mouthtype`. Uninstalling the app does not remove this data. Quit Mouthtype before removing the app; do not delete your data folder unless you intend to erase it.

## Report a problem

Include the app version, macOS version, destination app, what you said, what appeared, and any warning. Say whether text appeared once, twice, or not at all. Send only the transcript/audio you choose to share; logs and recordings can contain private dictation. Use the private repository’s issue tracker or your existing contact with Scott.
