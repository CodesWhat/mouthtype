# Technical notation follow-up, 2026-10-14

Shared deterministic formatting closes much of S1-mini's gap on the existing regression set without adding one dictionary entry per technical term. This is a pipeline improvement, not model training. The app's default and model-selection UI are unchanged, and this source has not been installed.

| Model and set | Passed | Model/check median | Full cleanup median | Full cleanup p95 |
| --- | ---: | ---: | ---: | ---: |
| S1-mini, main 66 | 64/66 | 77.0 ms | 77.3 ms | 137.8 ms |
| Gemma 4 E4B, main 66 | 66/66 | 716.0 ms | 715.8 ms | 872.3 ms |
| S1-mini, additional 10 | 10/10 | 75.0 ms | 74.8 ms | 81.2 ms |
| Gemma 4 E4B, additional 10 | 10/10 | 674.5 ms | 674.7 ms | 701.4 ms |

The preceding reviewed report measured S1 at 48/66 and Gemma at 64/66. The initial S1 baseline was 41/66. These are repeated tuning cases, not a general accuracy estimate or evidence of Wispr parity. The additional ten cases were written before these model runs and cover related patterns; they are additional regressions, not an independent held-out evaluation.

## Behavior

A shared notation stage joins spelled uppercase acronyms, including repeated letters, formats USB-A/B/C, and preserves literal labels and explicit dictionary/snippet spellings. It skips ambiguous name initials and protects code, filenames, paths, email addresses and backtick text. Nearby spellings also protect project identifiers. The number formatter converts spoken resolutions directly before device/resolution nouns, such as “five K display,” while retaining ordinary quantities such as “four K races.” The stage runs with deterministic cleanup and again after model output, so these fixes benefit both models and Basic cleanup. Off bypasses them.

Configured phrase replacements keep priority. This change does not add snippet storage or management UI; that remains separate roadmap work.

## Measurement and verification

Release arm64 on Apple M4 Pro / 48 GB, cached models, Light/Formal and production deadlines. Runs were sequential, separate from model tests. One warm sample per case; initial model loading is excluded. Model/check timings retain the existing metric. Full cleanup includes the deterministic stages and smart-cleanup processing, including postprocessing and guards, but excludes recognition, audio capture, model preparation and paste. Timing differences between these runs do not establish a speed improvement. Both metrics and every result are retained in the JSON.

All 1,066 tests pass: 561 Mac, 489 Core and 16 Fn. This includes real-model checks and both opt-in audio manifests. New red/green regressions cover technical formatting, literal/dictionary/nearby-spelling protection, disabling the stage, Unicode edit replay, idempotence and full-cost timing serialization. The release benchmark executable builds successfully. No desktop focus, paste, restart or installation was used for this follow-up.

## Remaining automatic-check failures

- s1Release, `normalization-cases:context-name`: 'Send this to merry.'. not one of the accepted outputs.
- s1Release, `normalization-cases:held-out-context-john`: 'The meeting is with Jon.'. not one of the accepted outputs.

A passing fallback proves preservation for that case, not successful model cleanup. Outcome counts in the JSON distinguish fallback from accepted generation. Name ambiguity remains follow-up work; these formatting improvements do not solve it.

Reproduce the main set by concatenating the four fixture arrays named in the JSON, prefixing case IDs with each fixture stem to retain uniqueness. Run `swift run -c release mouthtype-bench clean --smart light --cleaner superwhisper-s1-mini --file <fixture> --result <output.json>`, then repeat with `--cleaner gemma-4-e4b-it-4bit`. Run the additional fixture separately with the same settings. Models must already be cached. A nonzero exit still writes results when automatic checks fail. Run benchmarks sequentially, separately from real-model tests.

Measurements were captured at 9a41805. Review follow-up extends device matching to plural nouns and parses complete spoken resolution numbers through the existing number parser. Those changes have dedicated red/green cases, including the 32 limit and preservation of digit input; the timing table was not rerun for that follow-up.
