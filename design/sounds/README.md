# Mouthtype sounds

Click is the chosen default: bright, soft key-down to start; duller key-up to stop. Its matching lock and error cues also ship. The app bundles only those four WAVs from `Sources/MouthtypeMac/Resources/Sounds/Click` and preloads them before recording starts.

Soft, Glass, Wood, Pager, Breath, Pluck and Keys are preserved here for a later customization picker. Cancel and pasted cues are also kept for later use. They're design assets, not additional runtime settings.

All WAVs are original synthesized mono 48 kHz, 16-bit PCM. The generator uses fixed seeds and Python's standard library. Regenerate with `python3 -I design/sounds/build.py`. If changing a shipped Click cue, copy its regenerated WAV into the app resources and verify playback and recognition with the microphone.

The macOS Pop cue previously used for stop contains two audible-energy pulses about 70 ms apart. Click stop is a single decaying thunk lasting about 100 ms; playback loops are disabled.
