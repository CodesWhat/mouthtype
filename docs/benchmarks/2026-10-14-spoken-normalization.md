# Spoken normalization, 2026-10-14

Gemma 4 E4B is the selected local cleanup model. This comparison targets spoken-to-written formatting rather than only preserving technical text that is already formatted. This report records the earlier configurations; later changes are covered in [long-dictation deadlines](2026-10-14-long-dictation.md) and [faithful cleanup](2026-10-14-faithful-cleanup.md).

| Model | Passes | Development (37) | Held out (10) | Median | p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| superwhisper-s1-mini | 28/47 | 25 | 3 | 74 ms | 99 ms |
| gemma-4-e4b-it-4bit | 43/47 | 34 | 9 | 686 ms | 801 ms |
| qwen3-4b-instruct-2507-4bit | 36/47 | 29 | 7 | 912 ms | 1067 ms |

Measured on Apple M4 Pro / 48 GB, release arm64, using cached local models. Time is the model pass through its delivery checks after warm-up, excluding model loading. One sample per case. S1 uses its native prompt; general models use the shared prompt and bounded cursor context. These are product configurations, with different deadlines, rather than a controlled model-only ranking.

## What changed

- Gemma 4 E4B replaces S1-mini as the app default; S1 remains in the benchmark catalog.
- Spoken letters, connector types, resolutions and file/version notation are explicit cleanup tasks.
- Two- and three-word phrases reach cleanup. Single-word responses remain immediate.
- Repeated letters inside spelled acronyms survive the filler pass.
- Checks preserve acronym letters, quantities, negations and question intent while accepting equivalent written notation.
- Reference text is bounded to 600 characters before the cursor and 300 after it, kept separate from the transcript. Exact context copying is rejected.
- The original general-model configuration used a clarity instruction for Medium, removed in the later faithful-cleanup follow-up. Unresolved explicit corrections get a separate focused pass on the same model, within the shared deadline. Cursor blending is reapplied after generation.

## Regression checks

- Original acceptance cases, light: 13/19.
- Original acceptance cases, medium: 14/19.

The original strict checks still report spelling and punctuation differences: three versus 3, or a missing terminal period. These checks were not weakened. The real unresolved clock correction was fixed with a focused correction pass; the final corrected number or name must now survive the preservation check.

- Focused clock/correction regressions under release production deadlines, light: 4/4.
- Focused clock/correction regressions under release production deadlines, medium: 4/4.

## Remaining failures

- `resolution-eight`: `ok`. Delivered: "8K camera". not one of the accepted outputs.
- `context-name`: `guard-rejected`. Delivered: "Send this to merry". surrounding text copied into output.
- `context-project`: `guard-rejected`. Delivered: "The dry dock build passed". surrounding text copied into output.
- `held-out-ssd`: `ok`. Delivered: "SSD drive". not one of the accepted outputs.

## Scope and reproduction

The normalization-cases.json fixture contains ASR-shaped text, not audio. The 37 development examples cover abbreviations, numbers, names, code, corrections, negation and ordinary-language counterexamples. Ten later variants were held out from the initial prompt work. Exact alternatives tolerate case and selected punctuation variants, but can still flag harmless article omissions.

This is not evidence of Wispr parity. Nearby-name correction remains unreliable, and rejected or late output falls back to deterministic cleanup. Existing tests also check transcript storage, insertion logic, silence detection and recovery; no live desktop dictation or paste tests were run for this change.

Re-run from the repo root: `swift run -c release mouthtype-bench clean --smart light --cleaner gemma-4-e4b-it-4bit --file Sources/mouthtype-bench/Fixtures/normalization-cases.json`. The comparison command loads cached models offline and refuses missing ones. A nonzero exit means at least one fixture failed; it still writes outputs when `--result` is supplied.

Detailed inputs, proposed text, delivered text, outcomes and timings are in the adjacent JSON report.

## Nearby spelling follow-up

The earlier comparison table records the original prompt configuration. The updated app sends a bounded list of possible spellings extracted from nearby text, rather than sending the raw nearby sentences and field labels. These hints are separate from the user's dictionary and never force deterministic replacements. A delivery check also preserves a nearby spelling that the transcript already matches, allowing explicit spoken corrections.

| Check | Passes | Median | p95 |
| --- | ---: | ---: | ---: |
| Original 47 cases, Light | 44/47 | 684 ms | 781 ms |
| Focused context cases, Light | 11/12 | 761.5 ms | 785 ms |
| Focused context cases, Medium | 11/12 | 809 ms | 831 ms |
| Clock corrections, Light | 4/4 | 881.5 ms | 1096 ms |
| Clock corrections, Medium | 4/4 | 891.5 ms | 1101 ms |

The 47-case run improves from 43 to 44 passes with no new failures. Mary and John are corrected while retaining the dictated request. Ordinary uses of merry, mark, may and dry dock retain their meaning and casing, and an unrelated spoken name is preserved. Both cleanup levels were checked. All runs use release production deadlines, cached local models and synthetic text; no live microphone or clipboard testing was performed.

The focused suite includes an ambiguous Mary/Merry example. The model still chooses the wrong name, but the new guard rejects that substitution and delivers the original lowercase merry. The automatic checks ignore case, so its pass is a safe fallback, not evidence that name casing is solved. The remaining focused failure is joining dry dock into the project name Drydock. The other two failures in the 47-case set remain the omitted articles in 8K camera and SSD drive.

All 1,030 tests passed (556 Mac, 458 Core, 16 Fn), including spelling extraction, bounded/deduplicated Unicode hints, ordinary-word handling, name preservation and explicit-correction exceptions. The signed app was reloaded after checking for active dictation jobs. Detailed follow-up inputs, proposed/delivered text, outcomes and timings are included under nearbySpellingFollowUp in the adjacent JSON report.
