# Known limits for 0.6.0

> [!NOTE]
> This page covers what 0.6.0 doesn't promise. Most of it is evidence the maintainer didn't collect, not behavior known to be broken. For fixes to problems you can hit today, see [troubleshooting](TROUBLESHOOTING.md).

## Not verified

| Area | What isn't verified | Safe assumption |
| --- | --- | --- |
| Fresh install | Installing on a Mac that has never run Mouthtype wasn't verified for 0.6.0. That was a maintainer scope decision. | The first-run permission prompts and model downloads were tested only on machines that already had grants and caches, so they may behave differently on yours. |
| Non-English speech | Dictation in languages other than English was checked with fixtures and synthetic voices, not by people speaking those languages on a Mac. Auto-detect's language picks weren't measured on real speech. | Expect more corrections outside English, most of all in the Beta languages. Pick the language yourself if Auto-detect guesses wrong. |
| New screens | The Models page, the name accuracy card, the test take, the Microphone page and the cleanup instructions were checked by renders and tests, not by using them on a device. | They should work as described, but nobody has run through them on a Mac for this release. |
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
- Languages other than English get fewer cleanup rules. Fillers, spoken commands, counted lists, self-correction, number formatting and swearing removal are English only, and Fast cleanup uses Basic. Thorough covers German, Spanish, French, Italian, Portuguese, Dutch, Polish and Russian. Hindi, Tamil and other Indian languages and Japanese aren't supported yet. See [languages](LANGUAGES.md).
- Linux is experimental and source-only, with no supported desktop release.

> [!WARNING]
> Long terminal pastes can lose text. Split pastes are off by default and are not proof of insertion.

For the evidence behind each item, see [release readiness](RELEASE-READINESS.md).
