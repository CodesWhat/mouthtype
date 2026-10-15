# Read-through cleanup follow-up, 2026-10-14

The app now uses the general cleanup model's production deadline. Its launch path previously supplied the native cleaner's shorter default even without a diagnostic override. That made ordinary dictations fall back before Gemma could finish, despite passing the benchmark configuration.

Project-name joining requires a known spelling and explicit software context. “The dry dock build passed” can become “The Drydock build passed”; “the boat is still on the dry dock” keeps its ordinary meaning. Nearby names alone aren't enough to force a join. Joined dictionary spellings follow this rule when model cleanup is enabled; deterministic-only dictionary behavior is unchanged.

| Release check | Passed | Median | p95 |
| --- | ---: | ---: | ---: |
| Spoken normalization, Light | 45/47 | 688 ms | 805 ms |
| Project names and ordinary phrases, Light | 12/12 | 784.5 ms | 835 ms |
| Project names and ordinary phrases, Medium | 12/12 | 836.5 ms | 880 ms |
| Sentence-separated corrections, Light | 3/3 | 1082 ms | 1459 ms |
| Sentence-separated corrections, Medium | 3/3 | 1125 ms | 1505 ms |
| Clock corrections, Light | 4/4 | | |
| Clock corrections, Medium | 4/4 | | |

Measured on Apple M4 Pro / 48 GB using cached Gemma 4 E4B, release arm64, production deadlines, one run per case. The adjacent JSON contains proposed and delivered text, outcomes and timings. Project-name checks require exact casing. The remaining normalization mismatches are omitted articles in “8K camera” and “SSD drive.” These small regression sets don't establish general dictation accuracy or Wispr parity.

The signed app's file-only pipeline also replayed four saved practice recordings. Repetition removal, multiple corrections, technical notation and ordinary uses of mark/may/merry/dry dock all passed, taking 898, 1471, 1122 and 1018 ms respectively. The technical recording produced “3-D glasses,” “USB-C,” “4K,” “app.swift” and “2.3.1.” Audio and private recording paths are not included here. These replays exercised the app launch configuration without typing into another application.

The corrections fixture covers Tuesday changed to Wednesday, 2:30 changed to 3, and five copies changed to six. The preservation check rejects an invented AM/PM qualifier. USB-C notation is accepted without treating the connector letter as a lost acronym.

## Reproduction

Run the release benchmark with `swift run -c release mouthtype-bench clean --smart light --cleaner gemma-4-e4b-it-4bit --file Tests/Fixtures/project-name-joining.json`. Repeat with `--smart medium`, then use `Tests/Fixtures/sentence-corrections.json`. Normalization uses `Sources/mouthtype-bench/Fixtures/normalization-cases.json`. Models must already be cached. A nonzero exit reports fixture mismatches even when a JSON result is written.

## Delivery validation

Coordinated desktop checks confirmed one exact Paste Last insertion in a browser field and in a dedicated Terminal input capture. Native insertion diagnostics passed readback, clipboard restoration and failed-delivery handling. Recovery diagnostics passed interrupted-audio recovery, queued insertion and microphone-disconnect actions. Electron was not tested.

Terminal exposed a false failed-paste warning: its accessibility screen doesn't prove whether the foreground program consumed input. The source now treats Apple Terminal readback as unknown instead of reporting loss. That follow-up passes the Mac suite but hasn't been installed during the user's practice session. The same applies to the brighter, immediate processing-pill fix. The installed cleanup build and these later source fixes must not be treated as the same artifact.
