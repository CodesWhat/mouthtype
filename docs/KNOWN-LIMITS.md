# Known limits for 0.12.1

> [!NOTE]
> This page covers what 0.12.1 doesn't promise. Most of it is evidence the maintainer didn't collect, not behavior known to be broken. For fixes to problems you can hit today, see [troubleshooting](TROUBLESHOOTING.md).

## Not verified

| Area | What isn't verified | Safe assumption |
| --- | --- | --- |
| Fresh install | Installing on a Mac that has never run Mouthtype wasn't verified for 0.12.1. That was a maintainer scope decision. | The first-run permission prompts and model downloads were tested only on machines that already had grants and caches, so they may behave differently on yours. |
| Non-English speech | Dictation in languages other than English was checked with fixtures and synthetic voices, not by people speaking those languages on a Mac. Auto-detect's language picks weren't measured on real speech. | Expect more corrections outside English, most of all in the Beta languages. Pick the language yourself if Auto-detect guesses wrong. |
| Japanese, Hindi and Tamil (Beta) | These languages were checked with synthetic speech only, never a fluent speaker or a physical microphone. The Whisper Turbo model is a separate 1.6 GB download, and live words are unavailable while it is in use, including English takes in an Auto-detect set that contains these languages. | Expect more corrections than in the Parakeet languages. Cleanup is Basic only, and the download path hasn't been run on a fresh machine. |
| Press Return after inserting | The list in Settings > Advanced was checked with unit tests and offscreen renders only, never in a live app. | Try it in a throwaway chat before relying on it. Terminals can't confirm a paste, so when you add one Mouthtype presses Return a moment after the paste without checking. Other apps send only when Mouthtype can confirm the text landed. Neither has been tried in live apps yet. |
| New screens | The Models page, the name accuracy card, the test take, the Microphone page and the cleanup instructions were checked by renders and tests, not by using them on a device. | They should work as described, but nobody has run through them on a Mac for this release. |
| Bluetooth and USB microphones | Not physically verified. Microphone removal, reconnection and sleep are only lightly covered. | Built-in microphones are the tested path. Setup's microphone status can lag a recovered input until you return to the app and refresh it. |
| History playback | Play/Stop and capture/lifecycle behavior have automated coverage, but speaker output has not been verified on a device. | Missing or expired audio cannot be recreated by playback; text remains available. |
| Achievements | Trophy rules, the backfill and the toast are covered by tests and renders, and nobody has used the shelf or toast with VoiceOver on a Mac. | Trophies only count what is already on this Mac. Turn Achievements off in Settings > Mac if the toast gets in the way. |
| Support links | The menu bar and About panel links were checked in tests, not opened in a live default browser. | They should open GitHub Sponsors and the Donate page in your default browser. |
| Edit Selection by Voice | Automated tests cover the flow, but it was not run on a device after its final review fixes. | Check the preview before you accept. Nothing changes until you do. |
| Typing calibration | Scoring is covered by tests, and the Stats card has not been used with VoiceOver. | Your measured speed only affects the time-saved figure. |
| Speech recognition engine | FluidAudio 0.18.0 was not checked on real speech, including long takes. | Expect the same accuracy as before, but report any change in long takes. |
| VoiceOver | Acceptance testing is deferred. | Controls have accessibility identifiers and render correctly offscreen, but that doesn't show they work with VoiceOver. |
| Update installation | Other macOS versions and fresh installs aren't verified. | Signed update checks are tested. An update from one release to the next was observed installing and relaunching on one Mac. |
| Other apps | Other browsers, terminals and Electron apps need more testing. | TextEdit and Chrome have physical coverage. An unknown delivery status isn't proof the text failed to land. |

## Appearance

| Problem | Workaround |
| --- | --- |
| Clear Glass over a dark window on a light wallpaper can be hard to read. Glass picks clear or smoked from the wallpaper it measures, so a dark window behind it on a bright desktop can lower the contrast. | Switch Pill style on the Appearance page. Under Reduce Transparency, Glass is solid instead. |
| The Matrix padlock sprite is low-detail at its 9 px size. It's a pixel-art sprite. | Choose Pill size Large (Settings → Appearance) for more room. |
| The Hi-Fi ears and 4 px gap were positioned by eye and haven't had a physical display check. | Use Classic if the spacing looks wrong on your display. |
| The Hi-Fi card falls back to the Classic card for text its pixel font can't draw. Characters outside the font's range would turn into question marks. | Nothing to do. The card shows your text in the Classic style instead, and the text is unchanged. |

## Secure Input

- Secure Input safeguards depend on the destination's accessibility metadata. An allowed text role with no failed security reads and no subrole is accepted based on the app's report. Requiring a writable value or a caret range has not been validated as a stronger discriminator.

## Recognition and cleanup

- Names and context-dependent words can be recognized wrongly. Check text before sending. Mouthtype doesn't read earlier chat messages to resolve them.
- Cleanup models don't paraphrase. Ambiguous names are still a gap, especially with Fast.
- Languages other than English get fewer cleanup rules. Fillers, spoken commands, counted lists, self-correction, number formatting and swearing removal are English only, and Fast cleanup uses Basic. Thorough covers German, Spanish, French, Italian, Portuguese, Dutch, Polish and Russian. Japanese, Hindi and Tamil are supported in Beta with Basic cleanup; other Indian languages are not supported. See [languages](LANGUAGES.md).
- Linux is experimental and source-only, with no supported desktop release.

> [!WARNING]
> Long terminal pastes can lose text. Split pastes are off by default and are not proof of insertion.

## Linux

- **Accepted on one desk only.** The Linux client targets x86_64 Arch/Omarchy with Hyprland and PipeWire. The full flow (microphone takes, pill, paste delivery, file import and local cleanup) ran on one Arch/Omarchy desk. HiDPI, multi-monitor, other distros and other compositors haven't been tried, and automated tests use fake capture, fake engines and sockets.
- **Fast and Thorough cleanup are slower than on the Mac.** Basic is on by default. Fast (S1-mini) and Thorough (Qwen3 4B, not the Mac's Gemma) run on the CPU through a local llama.cpp server, after an explicit prepare step. Thorough took about 2.7 seconds for a short take on the maintainer's test machine and 38 seconds at 220 words, while its time budget is capped at 30 seconds, so long takes (roughly 140 words and up) are likely to time out and keep the Basic text. The Basic text is kept when a model times out, fails, or its output trips the guards that check for dropped negations, numbers and names. Those guards are heuristics and can miss a changed word.
- **Delivery is recovery-only until you choose otherwise.** The Omarchy plugin asks on first open whether to paste; typing is opt-in. Hyprland window identity doesn't show which field has focus or whether it's a password field, so there's no secure-field detection or insertion check, and a successful helper exit doesn't prove the text landed.
- **Paste restore is partial.** The earlier clipboard is put back only if it was text. An image or file clipboard is overwritten and not restored, a password manager's sensitive hint isn't carried over, and a slow target can read the restored text instead.
- **Raw hold bindings aren't ordered.** The hold examples in `hyprland.lua`, `hyprland-legacy.conf` and the client README launch separate press and release clients with no ordering, so a delayed press can start recording after the key is up. The Omarchy plugin's hold shortcut goes through its own ordered wrapper, and automated tests confirm a press delivered after its release never leaves a take recording, in every arrival order of rapid taps. Neither has been tested on real Hyprland hardware. Use toggle with the raw examples.
- **The pill can stall during delivery.** Delivery runs while the session holds its lock, so status and the pill can freeze for a few seconds during a paste, and up to 15 seconds if `wtype` hangs.
- **Imported files go through the system `ffmpeg`.** One WAV, AIFF or M4A file up to 10 minutes and 512 MB is accepted, with no cleanup pass. The content check also lets MP4-family containers through as M4A and decodes only their first audio stream.
- **No live word previews.**

For the evidence behind each item, see [release readiness](RELEASE-READINESS.md).
