# Architecture

Mouthtype is a single-user, local macOS 26 menu bar dictation app written in Swift 6.2 (`Package.swift`). Speech recognition and text cleanup run on the Mac. The only network traffic is model downloads and update checks. For the security view of the same boundaries, see [SECURITY.md](SECURITY.md).

## Targets

| Target | Kind | What it holds |
| --- | --- | --- |
| `MouthtypeCore` | library | Platform-light logic. Speech engines (`ParakeetEngine`, `WhisperEngine`), the deterministic text pipeline (`Text/`), model cleanup (`MLXCleaner`, `AppleCleaner`), model catalogs and pins, the hotkey gesture state machine (`Gesture/`), and the SQLite store (`Store/`). |
| `MouthtypeMac` | library | Everything that touches macOS. Audio capture, event taps, Accessibility, text insertion, the pill and delivery card, settings windows, automation, and the Sparkle updater. Depends on `MouthtypeCore`, `FnRemapKit` and Sparkle. |
| `Mouthtype` | executable | The app entry point. `main.swift` starts `NSApplication` as an accessory app and hands over to `AppDelegate` from `MouthtypeMac`. |
| `FnRemapKit` | library | Reads and writes the HID `UserKeyMapping` property for the opt-in Fn remap. |
| `mouthtype-fn-guard` | executable | A small helper the app launches with its parent pid. When the parent exits, it removes the Fn remap so a crash can't leave the keyboard remapped. |
| `mouthtype-bench` | executable | Developer benchmark for engines and cleaners, built on `MouthtypeCore` and swift-argument-parser. Not shipped in the app. |

Tests live in `Tests/` as `MouthtypeCoreTests`, `FnRemapKitTests`, `MouthtypeMacTests` and `MouthtypeSettingsUITests`. Third-party dependencies are FluidAudio, WhisperKit, mlx-swift-lm, swift-huggingface, swift-transformers, GRDB and Sparkle (pinned `exact: "2.10.0"`).

## Dictation pipeline

`DictationController` (in `MouthtypeMac/Dictation/`) drives one dictation at a time from hotkey events. `DictationPipeline` runs the stages.

1. **Trigger.** `HotkeyService` watches a `CGEvent` tap (`Input/EventTap.swift`). The tap is created only after Accessibility is granted. `Gesture/` in the core decides hold, tap, double-tap lock (hands-free) and cancel.
2. **Capture.** `AudioCapture` runs an AUHAL input unit (`HALInput`) and converts to 16 kHz mono Float32. The unit runs only while recording. A recording stops at 20 minutes, with a warning at 19, and a partial is flushed to disk every 5 seconds for crash recovery.
3. **Trim and voice check.** `SilenceTrimmer` cuts leading and trailing silence with an energy threshold. A capture with no voiced frames ends as empty without reaching the engine.
4. **ASR.** The engine comes from `EngineCatalog`: Parakeet v3 and v2 (FluidAudio, Core ML) and two Whisper variants (WhisperKit). `ParakeetEngine` also runs Silero VAD through FluidAudio's `VadManager`, and can bias recognition toward saved dictionary words and editor names.
5. **Guard.** `TranscriptGuard` drops words and tags that shouldn't be delivered and marks the take empty when too little voiced audio or no words remain.
6. **Deterministic cleanup.** `TextPipeline` runs fixed stages in order: fillers, slash commands (coding targets only), spoken commands, self-corrections, counted lists, notation, numbers, dictionary, snippets, profanity (Formal only), blend, style, whitespace.
7. **Model cleanup (optional).** `CleanupLevel` is off, basic, Fast (`light`) or Thorough (`medium`). Basic is the deterministic pass alone. Fast and Thorough add a local MLX model through `CleanerHost`: Superwhisper S1-mini for Fast and Gemma 4 E4B for Thorough (`CleanerCatalog`). A guard (`SmartCleanupGuard`) and fallbacks keep the deterministic text when the model pass fails or drifts. `AppleCleaner` and `ClaudeCLICleaner` exist in the catalog for benchmarks; the app's cleanup paths don't select them.
8. **Insertion.** `TextInserter` writes the text to the pasteboard, posts Cmd+V to the target process, then restores the user's clipboard. It snapshots the focused element over Accessibility at start and again before delivery, refuses secure fields and changed destinations, and verifies the paste by re-reading the field. Text it can't place stays recoverable.
9. **Record.** `TranscriptStore` logs the take, timings, edits and status. Audio is kept per the [retention policy](AUDIO-RETENTION.md).

File transcription (`MouthtypeMac/FileTranscription/`) reuses the same engine and cleanup on a decoded audio file and returns text for Copy or Save. See [FILE-TRANSCRIPTION.md](FILE-TRANSCRIPTION.md).

## Models: download and cache

Speech and cleanup models are not bundled. They download on first use and then run offline.

- `ModelPins` pins each speech model (Parakeet v3 and v2, the CTC-110M vocabulary model, Silero VAD, WhisperKit) to a Hugging Face commit. `CleanerCatalog` pins each MLX cleanup model the same way.
- Parakeet and VAD downloads go through FluidAudio into its cache directory, with the pins applied through `ModelRegistry.revisionOverrides`. Whisper and MLX models download through `HubApiWrapper` and `HubDownloader` into the shared Hugging Face hub cache (`HubCache.default`).
- `HubDownloader` serves a complete cached snapshot without touching the network. `ModelCacheAdoption` checks an older FluidAudio cache against the bundled `ModelManifest.json` (generated by `scripts/generate-model-manifest.py`) so a first launch with no network doesn't re-download.
- Progress comes from `ModelDownloadProgress`. A cancelled cleanup download is deleted.

## Settings and persistence

- **Preferences** are `UserDefaults` in the `com.codeswhat.mouthtype` domain, wrapped by small types such as `CleanupSettings`, `PasteSettings` and `RecordingModePreference`. `SettingsModel` backs the settings UI.
- **History and stats** are one SQLite database, `~/Library/Application Support/Mouthtype/mouthtype.sqlite`, opened with GRDB (`TranscriptStore`) and migrated on launch.
- **Audio** is stored as 16 kHz WAV files in `audio/` next to the database (`AudioArchive`), expired by `AudioRetentionPolicy`.

## Updates

Sparkle 2 (`MouthtypeMac/Updates/`). `Info.plist` sets `SUFeedURL` to `https://mouthtype.app/updates/appcast.xml`, and `UpdateLaunchPolicy` refuses to start the updater unless the feed URL matches and `SUPublicEDKey` decodes to a 32-byte key. Installation waits until the app isn't recording, processing or transcribing (`UpdateActivity`). Release and signing steps are in [RELEASING.md](RELEASING.md).

## Automation: URL scheme and CLI

`Info.plist` registers the `mouthtype://` scheme. `AutomationURL` parses a URL and `AutomationRouter` maps it to the same actions the menu and hotkeys use (start, stop, toggle, cancel, copy-last, paste-last, open a page). Verbs that record, copy or insert are refused unless the `automationEnabled` default is on, because any web page can open a `mouthtype://` link. `scripts/mouthtype` is a shell wrapper around `open -g mouthtype://...`. There's no network listener. Details: [AUTOMATION.md](AUTOMATION.md).

## Fn remap

The Fn key can optionally be remapped to F19 at the HID layer (`FnRemap`) so the system Globe action doesn't fire. The original mapping is recorded in `UserDefaults` and restored on exit. `mouthtype-fn-guard` restores it if the app dies without cleaning up.

## Linux client

The Linux client under `tools/` is experimental, source-only and Python, not a build of the Swift targets. It shares no compiled code with them. `tools/linux-desktop` is a session service and CLI (`mouthtype-linux`) for Arch/Omarchy with Hyprland and PipeWire: it records with `pw-record`, runs a resident Parakeet worker (sherpa-onnx on CPU), and uses its own port of the cleanup stages. `verify_cleanup.swift`, `verify_phrases.swift` and `verify_spellings.swift` check that port against the Swift core. `tools/omarchy-plugin` is the bar frontend, and `tools/linux-engine-proof` and `tools/linux-gesture-proof` are headless proofs. Maintained by David Stahl. See [guides/linux.md](guides/linux.md).

## Trust boundaries

| Boundary | Where | What crosses it |
| --- | --- | --- |
| Microphone | `NSMicrophoneUsageDescription` and the `com.apple.security.device.audio-input` entitlement. `AudioCapture` | Audio is captured only while recording and stays on the Mac. |
| Accessibility | `AccessibilityAccess`, `FocusSnapshot`, `EditorAccessibility` | Needed for the event tap and for reading the focused field, so insertion can refuse secure fields and changed destinations. Editor hints are off by default. |
| Clipboard and synthetic keys | `TextInserter` | The pasteboard is borrowed to carry the text and restored afterward. Cmd+V is posted to the target app. |
| Network | Model downloads (Hugging Face) and Sparkle (`mouthtype.app`) | Model files in, update feed and archives in. Dictation text and audio aren't sent anywhere by the app's cleanup path, and the app has no telemetry code. Models are commit-pinned but not hash-checked beyond what each library does. |
| URL scheme | `AutomationRouter` | Untrusted input from any web page. Off by default for anything that records, copies or inserts. |
| Local files | Application Support directory | Database and recordings are not encrypted. Imported audio is decoded by platform and dependency code. |
| Developer tools | `mouthtype-bench` | The Claude CLI cleaner and judge can send input to that service. They're benchmark-only and must use synthetic data. |
