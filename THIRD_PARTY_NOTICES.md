# Third-party notices

Mouthtype is licensed under GPL-3.0. Parts of it are adapted from the projects below. Swift package dependencies, such as Sparkle, FluidAudio and WhisperKit, are pinned in `Package.resolved` and keep their own upstream licenses. The speech and cleanup models are downloaded on request and carry their publishers' terms. Each dependency and model is listed below with its license and the canonical text.

## Parrot

https://github.com/humanitas-labs/parrot, commit 0eb4708

Files adapted from Parrot:

- `scripts/build-app.sh`
- `packaging/Info.plist`
- `packaging/Mouthtype.entitlements`
- `Sources/MouthtypeCore/SilenceTrimmer.swift` and `Tests/MouthtypeCoreTests/SilenceTrimmerTests.swift`
- `Sources/MouthtypeCore/Text/PhraseMatcher.swift`
- `Sources/MouthtypeCore/Text/DictionaryReplacer.swift` and `Tests/MouthtypeCoreTests/DictionaryReplacerTests.swift`
- `tools/linux-desktop/spellings.py`, `spelling-fixtures.json` and `test_spellings.py` (matching behavior and fixtures ported from Core)
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

## Linux Unicode matching

`tools/linux-desktop/vendor/grapheme` contains the portable MIT `grapheme`
v0.7.2 runtime, Unicode 16.0 property data and conformance fixtures from
https://github.com/timendum/grapheme, commit
`56f7f2d16d54576290634b7484eeece52c538bcb`. Only its Python import paths are
changed to use the private package namespace. The exact upstream and shipped
file digests are in `provenance.json`. The full MIT notice, including the
PyPA, Mapbox, Alvin Lindstam and Timendum copyrights, is preserved in that
directory's `LICENSE` and included in Linux source/install payloads.

`tools/linux-desktop/spelling-unicode.json` contains Unicode 16.0 Alphabetic
and Numeric_Type ranges, with source URLs and SHA-256 provenance. Those data
and the vendored Unicode tables/tests are covered by the Unicode License v3,
preserved in `tools/linux-desktop/vendor/grapheme/UNICODE-LICENSE` and included
in Linux source/install payloads. Copyright © Unicode, Inc.

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

## Pixelarticons

Copyright (c) 2019 Gerrit Halfmann (https://github.com/halfmage/pixelarticons)

- Licence: MIT, `Sources/MouthtypeMac/Resources/Fonts/MIT-Pixelarticons.txt`
- Source: https://github.com/halfmage/pixelarticons, v2.4.2, `svg/{home,chart,book-open,arrows-horizontal,a-arrow-up,picture-in-picture,settings-cog}.svg`
- Used for: the seven sidebar icons in `Sources/MouthtypeMac/Resources/Settings/Icons/`, rasterised unchanged at one grid pixel per point to 24, 48 and 96 px template PNGs

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

## OpenWhispr

https://github.com/OpenWhispr/openwhispr, commit 5f9a88b

The correction learner (`src/utils/correctionLearner.js`) is ported to Swift: the word-level LCS diff, the edit-distance
similarity test with its 0.65 ratio, and the common-word filter. Files adapted from OpenWhispr:

- `Sources/MouthtypeCore/Corrections/CorrectionLearner.swift` and `Tests/MouthtypeCoreTests/CorrectionLearnerTests.swift`
- `Sources/MouthtypeMac/Insertion/PasteKeyResolver.swift`

```
MIT License

Copyright (c) 2024 OpenWhispr Team

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

## Swift package dependencies

None of these are modified. Versions are the ones pinned in `Package.resolved`. Each license text is the `LICENSE` file at
the upstream repository linked below, and Apache License 2.0 is at https://www.apache.org/licenses/LICENSE-2.0.

| Package | Version | License | Copyright | Source |
| --- | --- | --- | --- | --- |
| Sparkle | 2.10.0 | MIT, plus the bundled-component notices in its `LICENSE` | Andy Matuschak, Elgato Systems GmbH, Kornel Lesiński and others, as listed in that file | https://github.com/sparkle-project/Sparkle |
| FluidAudio | 0.17.7 | Apache License 2.0 | per upstream `LICENSE` and `NOTICE` | https://github.com/FluidInference/FluidAudio |
| WhisperKit | 1.1.1 | MIT | Copyright (c) 2024 argmax, inc. | https://github.com/argmaxinc/WhisperKit |
| mlx-swift-lm | 3.32.3 | MIT | Copyright (c) 2024 ml-explore | https://github.com/ml-explore/mlx-swift-lm |
| mlx-swift | 0.32.3 | MIT | Copyright (c) 2023 ml-explore | https://github.com/ml-explore/mlx-swift |
| swift-huggingface | 1.0.0 | Apache License 2.0 | per upstream `LICENSE` | https://github.com/huggingface/swift-huggingface |
| swift-transformers | 1.3.5 | Apache License 2.0 | per upstream `LICENSE` | https://github.com/huggingface/swift-transformers |
| swift-jinja | 2.5.1 | Apache License 2.0 | per upstream `LICENSE` | https://github.com/huggingface/swift-jinja |
| GRDB.swift | 7.11.1 | MIT | Copyright (C) 2015-2025 Gwendal Roué | https://github.com/groue/GRDB.swift |
| EventSource | 1.5.1 | MIT | Copyright 2025 Mattt | https://github.com/mattt/EventSource |
| yyjson | 0.12.0 | MIT | Copyright (c) 2020 YaoYuan | https://github.com/ibireme/yyjson |
| swift-argument-parser | 1.8.2 | Apache License 2.0 with Runtime Library Exception | Apple Inc. and the project authors, per source headers | https://github.com/apple/swift-argument-parser |
| swift-asn1 | 1.7.3 | Apache License 2.0 | Apple Inc. and the project authors, per source headers | https://github.com/apple/swift-asn1 |
| swift-collections | 1.7.2 | Apache License 2.0 with Runtime Library Exception | Apple Inc. and the project authors, per source headers | https://github.com/apple/swift-collections |
| swift-crypto | 4.5.2 | Apache License 2.0 | Apple Inc. and the project authors, per source headers | https://github.com/apple/swift-crypto |
| swift-numerics | 1.1.1 | Apache License 2.0 with Runtime Library Exception | Apple Inc. and the project authors, per source headers | https://github.com/apple/swift-numerics |
| swift-syntax | 603.0.2 | Apache License 2.0 with Runtime Library Exception | Apple Inc. and the project authors, per source headers | https://github.com/swiftlang/swift-syntax |

swift-syntax is a build-time dependency of other packages and is not part of the shipped app. The Sparkle framework is
embedded in `Mouthtype.app/Contents/Frameworks`, and its `LICENSE` file is the authority for the components it bundles.

## Models

No model is bundled with Mouthtype. Each is downloaded on request from Hugging Face and runs on the Mac. The license
named is the one on the model's Hugging Face card; follow the link for the full text and any use restrictions.

| Model | Used for | License | Card |
| --- | --- | --- | --- |
| Parakeet TDT 0.6B v3 (NVIDIA; Core ML conversion by FluidInference) | Speech recognition | CC BY 4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 and https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml |
| Parakeet TDT 0.6B v2 (NVIDIA; Core ML conversion by FluidInference) | Speech recognition, English | CC BY 4.0 | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2 and https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml |
| Parakeet CTC 110M (NVIDIA parakeet-tdt_ctc-110m; Core ML conversion by FluidInference) | Vocabulary boosting, only when you turn on "Boost my saved words while recognising" | CC BY 4.0 | https://huggingface.co/nvidia/parakeet-tdt_ctc-110m and https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml |
| Silero VAD (Core ML conversion by FluidInference) | Speech detection | MIT | https://huggingface.co/FluidInference/silero-vad-coreml |
| Whisper large-v3 turbo and small.en (OpenAI; Core ML builds by argmax) | Alternative speech recognition | MIT | https://huggingface.co/argmaxinc/whisperkit-coreml |
| S1-mini (Superwhisper) | Fast cleanup | Apache License 2.0 plus a naming clause, see the S1-mini section above | https://huggingface.co/superwhisper/s1-mini |
| Gemma 4 E4B it, MLX 4-bit (Google; conversion by mlx-community) | Thorough cleanup | Apache License 2.0, https://ai.google.dev/gemma/docs/gemma_4_license | https://huggingface.co/mlx-community/gemma-4-e4b-it-4bit and https://huggingface.co/google/gemma-4-e4b-it |

CC BY 4.0 requires attribution: the Parakeet models are by NVIDIA, licensed under
https://creativecommons.org/licenses/by/4.0/. The Core ML conversions are by FluidInference and are not endorsed by NVIDIA.

The catalog also lists optional cleanup models for benchmarking (Gemma 4 E2B, Qwen3 4B Instruct 2507, Llama 3.2 3B
Instruct, Phi-4-mini Instruct, all MLX 4-bit from `mlx-community`). They are not offered in the app, and each keeps the
license on its Hugging Face card.
