# Third-party notices

Mouthtype is licensed under GPL-3.0. Parts of it are adapted from the project below.

## Parrot

https://github.com/humanitas-labs/parrot, commit 0eb4708

Files adapted from Parrot:

- `scripts/build-app.sh`
- `packaging/Info.plist`
- `packaging/Mouthtype.entitlements`
- `Sources/MouthtypeCore/SilenceTrimmer.swift` and `Tests/MouthtypeCoreTests/SilenceTrimmerTests.swift`
- `Sources/MouthtypeCore/Text/PhraseMatcher.swift`
- `Sources/MouthtypeCore/Text/DictionaryReplacer.swift` and `Tests/MouthtypeCoreTests/DictionaryReplacerTests.swift`
- `Sources/MouthtypeMac/Audio/AudioCapture.swift`
- `Sources/MouthtypeMac/Audio/CaptureBuffer.swift`
- `Sources/MouthtypeMac/Audio/CaptureError.swift`
- `Sources/MouthtypeMac/Audio/ConverterCache.swift`
- `Sources/MouthtypeMac/Audio/HALInput.swift`
- `Sources/MouthtypeMac/Audio/HostClock.swift`
- `Sources/MouthtypeMac/Audio/InputDevice.swift`
- `Sources/MouthtypeMac/Audio/MicrophoneAccess.swift`
- `Tests/MouthtypeMacTests/CaptureBufferTests.swift`
- `Tests/MouthtypeMacTests/ConverterCacheTests.swift`
- `Tests/MouthtypeMacTests/HALInputTests.swift`
- `Sources/MouthtypeMac/Insertion/Delivery.swift`
- `Sources/MouthtypeMac/Insertion/FocusSnapshot.swift`
- `Sources/MouthtypeMac/Insertion/Spacing.swift`
- `Sources/MouthtypeMac/Insertion/TextInserter.swift`
- `Sources/MouthtypeMac/Pill/PillController.swift` (panel set-up only)
- `Sources/MouthtypeMac/Menu/LoginItem.swift`
- `Tests/MouthtypeMacTests/InsertionSpacingTests.swift`
- `Tests/MouthtypeMacTests/TextInserterTests.swift`
- `Sources/MouthtypeMac/Input/EventTap.swift`
- `Sources/MouthtypeMac/Input/HotkeyService.swift` (tap recovery and resync)
- `Sources/MouthtypeMac/Input/TapRecovery.swift`
- `Sources/MouthtypeMac/Permissions/GlobeKeyCheck.swift`
- `Tests/MouthtypeMacTests/HotkeyRecoveryTests.swift`

```
MIT License

Copyright (c) 2026 Humanitas Labs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Hex

https://github.com/kitlangton/Hex, commit f58d52c

Files adapted from Hex:

- `Sources/MouthtypeCore/Gesture/HotKeyProcessor.swift`
- `Sources/MouthtypeCore/Gesture/RecordingDecision.swift`
- `Sources/MouthtypeCore/Gesture/GestureConstants.swift`
- `Sources/MouthtypeCore/Gesture/HotKey.swift`
- `Sources/MouthtypeCore/Gesture/KeyEvent.swift`
- `Tests/MouthtypeCoreTests/HotKeyProcessorTests.swift`

```
MIT License

Copyright (c) 2025 Kit Langton

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Fonts

Three typefaces are bundled in `Sources/MouthtypeMac/Resources/Fonts/` and embedded in `design/board/prototype.html`.
All three are licensed under the SIL Open Font License, Version 1.1. They are bundled unmodified and stay under the
OFL; they are not sold on their own. The full licence text for each sits beside its font files.

### Instrument Serif

Copyright 2022 The Instrument Serif Project Authors (https://github.com/Instrument/instrument-serif)

- Licence: SIL OFL 1.1, `Sources/MouthtypeMac/Resources/Fonts/OFL-InstrumentSerif.txt`
- Source: https://github.com/Instrument/instrument-serif, commit 65c0ef225f386a3c7e87570a4aa9cc0262c2fd81 (no tagged release), `fonts/ttf/InstrumentSerif-Regular.ttf`
- Used for: the Systema set's headers and pill messages

### Instrument Sans

Copyright 2022 The Instrument Sans Project Authors (https://github.com/Instrument/instrument-sans)

- Licence: SIL OFL 1.1, `Sources/MouthtypeMac/Resources/Fonts/OFL-InstrumentSans.txt`
- Source: https://github.com/Instrument/instrument-sans, commit 7fa22308a3d0c94ee2b3cd537a1196b65db34a3e (no tagged release), `fonts/ttf/InstrumentSans-{Regular,Medium,SemiBold}.ttf`
- Used for: the Systema set's body text, pill details and buttons

### JetBrains Mono

Copyright 2020 The JetBrains Mono Project Authors (https://github.com/JetBrains/JetBrainsMono)

- Licence: SIL OFL 1.1, `Sources/MouthtypeMac/Resources/Fonts/OFL-JetBrainsMono.txt`
- Source: https://github.com/JetBrains/JetBrainsMono, tag v2.304 (commit cd5227bd1f61dff3bbd6c814ceaf7ffd95e947d9), `fonts/ttf/JetBrainsMono-Medium.ttf`
- Used for: the Systema set's clocks and countdowns

## S1-mini by Superwhisper

https://huggingface.co/superwhisper/s1-mini, revision 88f6b15896c73bbb13a3b596e0afe8ea0d5150b4

The local model behind light and medium cleanup. It is not bundled with Mouthtype. The user downloads it from Hugging
Face on request, and it runs on the Mac through MLX. It is a fine-tune of Qwen3-0.6B (Copyright 2024 Alibaba Cloud,
Apache License 2.0), Copyright 2026 Superwhisper.

- Licence: Apache License, Version 2.0, plus one additional term. The full text is the repository's `LICENSE` file
  (https://huggingface.co/superwhisper/s1-mini/blob/main/LICENSE) and `NOTICE`.
- Used for: cleaning each dictation after the deterministic pass (`Sources/MouthtypeCore/MLXCleaner.swift`,
  `Sources/MouthtypeCore/Smart/`)

The additional term, quoted from the `LICENSE`:

```
ADDITIONAL TERM

In addition to the terms of the Apache License, Version 2.0 above: any
use, distribution, or integration of this model, whether unmodified or
as part of a derivative work or product, must continue to identify it
by its original name, "S1-mini" by "Superwhisper", using that exact
capitalization, regardless of any other name under which the model or
a product incorporating it is marketed or distributed.
```

Wherever the app names the model it writes exactly `S1-mini by Superwhisper`. The string lives in
`CleanerCatalog.smartCleanupName`.
