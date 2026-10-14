# Fast cleanup follow-up, 2026-10-14

S1-mini by Superwhisper remains substantially faster on this local regression set. The app default is still Gemma 4 E4B. Fast/Thorough model selection has not been implemented or installed by this change.

| Configuration | Passed | Median | p95 |
| --- | ---: | ---: | ---: |
| S1-mini before shared fixes | 41/66 | 81.0 ms | 160 ms |
| S1-mini after shared fixes | 48/66 | 79.0 ms | 137 ms |
| Gemma 4 E4B after shared fixes | 64/66 | 703.5 ms | 852 ms |

The final S1 and Gemma runs were sequential, with no model-test runner or other benchmark process running. These are warm model cleanup and delivery-check times, excluding speech recognition, audio capture, loading and clipboard insertion. One sample per case, Apple M4 Pro / 48 GB, cached local models, release arm64, production word-based deadlines. Earlier Gemma timings collected concurrently with model tests were discarded. Timing differences between runs do not prove a speed improvement from the shared fixes.

## Changes

Native cleaners now receive the same conservative project-name joining and ordinary-word protection as shared-prompt models. A known spelling and explicit software context are required. The policy runs before generation and restores a split project spelling afterward only where the output also retains software context. An ordinary occurrence stays separate; an unsafe rewrite falls back to deterministic text.

The deterministic correction stage now resolves a full clock time corrected to a bare hour at a sentence boundary: “Make it two thirty actually three” becomes “Make it 3:00.” The explicit clock notation keeps the hour distinct from a following count correction when S1 normalizes the full passage. It does not carry abandoned minutes into 3:30, infer AM/PM, accept an out-of-range bare hour or erase a following quantity such as “three copies.” Explicitly spoken AM/PM is retained.

The benchmark now accepts `--s1-style` and `--s1-structure` for S1-mini comparisons. They do not change app preferences or model selection. The required native system prompt and thinking-disabled setting are unchanged. Supported controls and their intended behavior come from the [S1-mini model card](https://huggingface.co/superwhisper/s1-mini).

## Native-control comparison

This sweep preceded the bare-hour correction fix. It uses the same 66 cases, app Formal output style and production guards. These are product-output checks, so a setting that lowercases a project name can fail exact casing even when the words remain. Fallbacks can pass preservation checks without proving model success. The JSON separates outcomes from pass counts.

| Native style | Structure | Passed |
| --- | --- | ---: |
| casual | prose | 39/66 |
| casual | lists | 42/66 |
| semi-casual | prose | 41/66 |
| semi-casual | lists | 44/66 |
| semi-formal | prose | 46/66 |
| semi-formal | lists | 47/66 |
| formal | prose | 40/66 |
| formal | lists | 40/66 |

The existing semi-formal/list setting wins this set. No default control change follows from this sweep. Additional free-form prompt instructions are not an appropriate substitute for the model's trained input format.

## Verification and limits

All 1,056 tests pass across split runs: 561 Mac, 479 Core and 16 Fn. This includes the real-model checks with cached S1/Gemma, plus the opt-in English-script and speech/silence audio fixtures. The clock fixture now also accepts 3:00 and 5:00 as equivalents of the already accepted 3/three and 5/five; abandoned minutes and invented AM/PM remain excluded. New red/green regressions cover native joining, restoration after a model splits a project spelling, and bare-hour correction with ordinary-quantity counterexamples. A separate all-serial Mac test invocation stalled and was stopped; the normal Mac run passed. No desktop focus, app restart or paste was used for this follow-up.

The 66 cases contain ASR-shaped synthetic text, not new audio. Project names are 12 paired software/ordinary cases; faithful wording includes Messages, Mail and Slack contexts. This is a tuning set, not an independent accuracy estimate or evidence of Wispr parity. The JSON includes every final delivered output, proposed output, failure and outcome for inspection. Remaining failures must not be hidden by the aggregate pass count.

Reproduce each fixture listed in the JSON with `swift run -c release mouthtype-bench clean --smart light --cleaner superwhisper-s1-mini --file <fixture> --result <output.json>`. Repeat with `--cleaner gemma-4-e4b-it-4bit`. For native controls, add `--s1-style semi-formal --s1-structure lists` and compare the other trained values. Models must already be cached. A nonzero status still writes results when cases fail. Run the comparisons sequentially, separately from the real-model tests.

The timing table was captured at 7aa3b29. Follow-up review tightened sentence boundaries so opening parentheses, newlines and semicolons do not turn a following count into a clock correction, and added preservation of explicitly spoken AM/PM. Seven additional red/green counterexamples cover those cases; the timing table was not rerun for those edge-case checks.
