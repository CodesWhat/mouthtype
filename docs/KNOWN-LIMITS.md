# Known limits for 0.5.0

> [!NOTE]
> This page covers what 0.5.0 doesn't promise. Most of it is evidence the maintainer didn't collect, not behavior known to be broken. For fixes to problems you can hit today, see [troubleshooting](TROUBLESHOOTING.md).

## Not verified

| Area | What isn't verified | Safe assumption |
| --- | --- | --- |
| Fresh install | Installing on a Mac that has never run Mouthtype wasn't verified for 0.5.0. That was a maintainer scope decision. | The first-run permission prompts and model downloads were tested only on machines that already had grants and caches, so they may behave differently on yours. |
| Bluetooth and USB microphones | Not physically verified. Microphone removal, reconnection and sleep are only lightly covered. | Built-in microphones are the tested path. Setup's microphone status can lag a recovered input until you return to the app and refresh it. |
| VoiceOver | Acceptance testing is deferred. | Controls have accessibility identifiers and render correctly offscreen, but that doesn't show they work with VoiceOver. |
| Update installation | Other macOS versions and fresh installs aren't verified. | Signed update checks are tested. An update from one release to the next was observed installing and relaunching on one Mac. |
| Other apps | Other browsers, terminals and Electron apps need more testing. | TextEdit and Chrome have physical coverage. An unknown delivery status isn't proof the text failed to land. |

## Appearance

| Problem | Workaround |
| --- | --- |
| Clear Glass over a dark window on a light wallpaper can be hard to read. Glass picks clear or smoked from the wallpaper it measures, so a dark window behind it on a bright desktop can lower the contrast. | Switch Pill style on the Appearance page. Under Reduce Transparency, Glass is solid instead. |
| The Matrix padlock sprite is low-detail at small size. It's a pixel-art sprite. | Choose Pill size Large (Settings → Appearance) for more room. |
| The Hi-Fi card falls back to the Classic card for text its pixel font can't draw. Characters outside the font's range would turn into question marks. | Nothing to do. The card shows your text in the Classic style instead, and the text is unchanged. |

## Recognition and cleanup

- Names and context-dependent words can be recognized wrongly. Check text before sending. Mouthtype doesn't read earlier chat messages to resolve them.
- Cleanup models don't paraphrase. Ambiguous names are still a gap, especially with Fast.
- Linux is experimental and source-only, with no supported desktop release.

> [!WARNING]
> Long terminal pastes can lose text. Split pastes are off by default and are not proof of insertion.

## Linux

- **Not accepted on a real machine.** The Linux client targets x86_64 Arch/Omarchy with Hyprland and PipeWire. Automated tests use fake capture, fake engines and sockets. Microphone capture, the speech and cleanup models, paste and typing delivery, the login service and the shortcut bindings still need a recorded session on real hardware.
- **Cleanup is off by default and slower than on the Mac.** Fast (S1-mini) and Thorough (Qwen3 4B, not the Mac's Gemma) run on the CPU through a local llama.cpp server, after an explicit prepare step. Thorough took about 2.7 seconds for a short take on the maintainer's test machine and 38 seconds at 220 words, while its time budget is capped at 30 seconds, so long takes (roughly 140 words and up) are likely to time out and keep the Basic text. The Basic text is kept when a model times out, fails, or its output trips the guards that check for dropped negations, numbers and names. Those guards are heuristics and can miss a changed word.
- **Delivery is recovery-only by default.** Paste and typing are opt-in. Hyprland window identity doesn't show which field has focus or whether it's a password field, so there's no secure-field detection or insertion check, and a successful helper exit doesn't prove the text landed.
- **Paste restore is partial.** The earlier clipboard is put back only if it was text. An image or file clipboard is overwritten and not restored, a password manager's sensitive hint isn't carried over, and a slow target can read the restored text instead.
- **Raw hold bindings aren't ordered.** The hold examples in `hyprland.lua`, `hyprland-legacy.conf` and the client README launch separate press and release clients with no ordering, so a delayed press can start recording after the key is up. The Omarchy plugin's hold shortcut goes through its own ordered wrapper, but neither has been tested on real hardware. Use toggle with the raw examples.
- **The pill can stall during delivery.** Delivery runs while the session holds its lock, so status and the pill can freeze for a few seconds during a paste, and up to 15 seconds if `wtype` hangs.
- **Imported files go through the system `ffmpeg`.** One WAV, AIFF or M4A file up to 10 minutes and 512 MB is accepted, with no cleanup pass. The content check also lets MP4-family containers through as M4A and decodes only their first audio stream.
- **No live word previews.**

For the evidence behind each item, see [release readiness](RELEASE-READINESS.md).
