# Cleanup quality and budget, 2026-10-21

Fast (S1-mini) and Thorough (Gemma 4 E4B) were run before and after on the same 148 cases, one level at a time, with nothing else running (load 4 to 10). Apple M4 Pro / 48 GB, release arm64, cached models, production word-based deadlines, `clean --smart` with the app's own pipeline. Numbers are warm unless marked.

The brief for this run said Fast passed 15 of 19 acceptance cases. On this branch it already passes 19 of 19. The 15 of 19 is Thorough: three "coffee at 3." cases (Gemma left "three" as a word) and one question that Gemma turned into a statement.

| Measure | Fast before | Fast after | Thorough before | Thorough after |
| --- | ---: | ---: | ---: | ---: |
| Acceptance cases (smart-cases) | 19/19 | 19/19 | 15/19 | 19/19 |
| Cleanup and normalization cases | 90/122 | 92/122 | 92/122 | 95/122 |
| Long takes (35 to 395 words) | 8/8 | 8/8 | 8/8 | 8/8 |
| Guard rejections (of 143 model runs) | 15 | 7 | 21 | 13 |
| Timeouts on the long takes | 1 | 0 | 0 | 0 |
| Delivered cleanup p50 / p95 | 91 / 1582 ms | 95 / 1622 ms | 287 / 4188 ms | 269 / 4124 ms |
| Model only p50 / p95 (75 cases x 3) | 132 / 1722 ms | 140 / 1664 ms | 341 / 4287 ms | 344 / 4487 ms |
| First clean after prepare | 106 ms | 68 ms | 842 ms | 187 ms |

Model-only and delivered latency are within run-to-run noise of each other (decode speed 68 and 69 tokens per second for Thorough, 160 and 165 for Fast); the changes here are about accepting correct output, headroom and the cold start, not steady-state speed.

## Where the time goes

Gemma decodes at about 68 tokens per second and its first output token arrives in about 80 ms with the shared prefix cached, so a take costs roughly 20 ms a word. Prefill is not the problem; decode is. The first clean after load took 842 ms against 340 ms steady, because kernel compilation and the first prefix-cache build land on the first take. The output-length bound (3 tokens a word plus 48, or twice the input tokens) was already in place and fires on none of these takes.

The old budgets left almost no headroom on long takes. Fast was 400 ms plus 12 ms a word capped at 2.5 s, while a 250-word take already needs about 2.2 s on a quiet machine. A 395-word take timed out at 2,624 ms on a quiet machine before the change and finished in 3,131 ms after. Thorough had 1.2 s plus 30 ms a word: a 395-word take needs about 7.2 s quiet against a 12 s cap, which a busy machine (2 to 3 times slower) exceeds. The old doubled allowance for a correction pass was also capped at 12 s in total, so past about 195 words each of its two generations got less time than a take with no correction pass. No Thorough timeout reproduced on a quiet machine; that fix is headroom, not a measured before and after.

## Changes

Budgets. Fast is now 400 ms plus 16 ms a word, at most 5 s. Thorough is 1.2 s plus 45 ms a word, at most 16 s per generation. A Thorough take with a correction pass gets that single-pass budget for each of its two generations, so it never has less time per generation than a take without one; the total tops out at 32 s instead of the old shared 12 s. A take still returns the moment it finishes; the budget only bounds a stall, and the output-token cap already bounds a runaway.

Warm-up. The bench's prepare step runs one real-shaped generation after loading, so its first-clean number matches what the app sees. The app already warms up after load in `CleanerHost`, so `MLXCleaner.load()` does not do it a second time.

Guard. Every rule below only treats a different spelling of the same value as equal, and each has a test that the wrong value still fails. A false accept costs more than a false reject, so a rule that could not be made that tight was narrowed or dropped.
- Cardinal phrases: "twenty four seven" may be 24/7. Each word keeps its own spelling and digits and the phrase adds its exact value.
- Tens plus ordinal: "twenty second" is accepted as "22nd" or as the words, never as "22" or "22-second".
- Scale words (hundred, thousand, million, billion) must be kept or folded into the written value: "fifteen hundred hours" may be "1,500 hours", but "five hundred thousand dollars" as "$500" or "$500 thousand", and "fifteen hundred" as "15", are rejected. A number's own phrase value can no longer vouch for a different input.
- Spoken years ("twenty twenty six" as 2026) are read only after a month name, or right after in, since, by or year when the year ends its clause. "twenty thirty minutes", "nineteen twenty people" and "twenty twenty six and forty" stay separate numbers.
- "at nine oh five" and "nine oh five p m" may be 9:05. Without a time cue "nine oh five" stays 905, and the colon form and the form without one never match each other. "four oh four" matches 404.
- Spoken digit strings with pauses ("five five five, oh one two three") match 555-0123.
- "A/B" matches "AB" only when "test", "tests" or "testing" follows. Other initials are left alone.
- AM and PM are paired with their own time ("9:00 AM", "5:00 PM"). Swapping them between times, moving them, or adding one to a bare hour is rejected.
- S1 writes "3:15pm" for "3:15 PM". When the input spelled times that way the model's text gets "3:15 PM" written back before the guard runs, and a model that changes AM to PM is still rejected.

Prompt (shared prompt, Thorough only). Rule 6 now says a bare hour is written as a numeral ("coffee at three" becomes "coffee at 3"), which fixes the three coffee cases. Rule 9 keeps the opening word of a question and gives the "what's the capital of France" example, which fixes the question Gemma rewrote as "The capital of France". The S1 native prompt is untouched.

## Left alone on purpose

Remaining Fast rejections (7): a translation request whose "Translate this sentence into Spanish:" the model dropped, a spoken self-correction that removed "not the regression run" (negation count), a self-correction that removed more than half the content words, a dropped "should" when the model turned a plan into a list, and three dictionary-name joins from the synthetic vocabulary conversion. Remaining Thorough rejections (13) add the injection prompts Gemma obeyed (pirate, banana, hello), a lost space in ".env.local", an invented surname, and a paraphrase of "ain't nobody got time". Those are model faults and the guard is right to reject them. The self-correction cases are a real tension; loosening them means teaching the guard what an abandoned span is, which is a follow-up, not a tuning change.

## Verification and limits

Filtered tests only (SmartCleanup, SmartCleanupGuard, CleanupPrompt via CleanerCatalog, PrefixCache, CleanupDeadline, NearbyNameGuard, SmartLiteral, CleanupBench, CleanerHost, CleanupSelection, SmartCleanupPipeline): 84 Mac and 160 Core tests pass. The full suite was not run.

The 148 cases are synthetic, ASR-shaped text. The 122-case set is `cleanup-cases.json` plus `normalization-cases.json` concatenated, with each case's vocabulary turned into a dictionary rule whose heard form is the lowercased written form; that conversion is what produces the three vocab-name rejections and is not how the app builds rules. Long takes are `Tests/Fixtures/long-takes.json`, written for this run. The history figures (31 timeouts, 29 rejections over 972 takes) come from a read-only analysis of the app's own database; that database was not opened here. The timeout figure averaged 875 ms at about 40 words, which matches the old Fast budget (880 ms), not Gemma's, so those timeouts were probably Fast under machine load. One sample per case for the delivered rows, three for model-only.

Reproduce one set with `swift run -c release mouthtype-bench clean --smart light --cleaner superwhisper-s1-mini --file <fixture> --result <output.json>`, then `--smart medium --cleaner gemma-4-e4b-it-4bit` for Thorough. Model-only timing is `mouthtype-bench cleanup-worker <cleaner> --mode full --runs 3 --result <output.json>`. Models must already be cached. Run them one at a time, separately from model tests. The JSON holds every delivered output, proposed output, failure and rejection reason for both runs.
