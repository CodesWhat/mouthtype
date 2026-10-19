# Known limits for 0.1.0

What 0.1.0 doesn't promise. Most of it is evidence the maintainer didn't collect, not behavior known to be broken. For fixes to problems you can hit today, see [troubleshooting](TROUBLESHOOTING.md).

## Not verified

- **Fresh install.** Installing on a Mac that has never run Mouthtype wasn't verified for 0.1.0. That was a maintainer scope decision. The first-run permission prompts and model downloads were tested only on machines that already had grants and caches, so they may behave differently on yours.
- **Bluetooth and USB microphones.** Not physically verified. Built-in microphones are the tested path. Microphone removal, reconnection and sleep are also only lightly covered, and Setup's microphone status can lag a recovered input until you return to the app and refresh it.
- **VoiceOver.** Acceptance testing is deferred. Controls have accessibility identifiers and render correctly offscreen, but that doesn't show they work with VoiceOver.
- **Update installation.** Signed update checks are tested. Installing an update over a running app and relaunching hasn't been verified end to end.
- **Other apps.** TextEdit and Chrome have physical coverage. Other browsers, terminals and Electron apps need more testing. An unknown delivery status isn't proof the text failed to land.

## Appearance

- **Clear Glass over a dark window on a light wallpaper can be hard to read.** Glass picks clear or smoked from the wallpaper it measures, so a dark window behind it on a bright desktop can lower the contrast. Switch Pill style under Settings → Appearance if it bothers you. Under Reduce Transparency, Glass is solid instead.
- **The Matrix padlock sprite is low-detail at small size.** It's a pixel-art sprite. Choose Pill size Large (Settings → Appearance) for more room.
- **The Hi-Fi card falls back to the Classic card for text its pixel font can't draw.** Characters outside the font's range would turn into question marks, so the card shows your text in the Classic style instead. The text is unchanged.

## Keyboard access

- **Settings controls are reachable with Tab only when macOS Keyboard navigation is on.** Turn it on in System Settings → Keyboard. With it off, macOS skips most controls when you press Tab.

## Recognition and cleanup

- Names and context-dependent words can be recognized wrongly. Check text before sending. Mouthtype doesn't read earlier chat messages to resolve them.
- Cleanup models don't paraphrase. Ambiguous names are still a gap, especially with Fast.
- Long terminal pastes can lose text. Split pastes are off by default and are not proof of insertion.
- Linux is experimental and source-only, with no supported desktop release.

For the evidence behind each item, see [release readiness](RELEASE-READINESS.md).
