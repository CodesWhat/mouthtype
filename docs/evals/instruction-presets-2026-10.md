# Instruction presets, October 2026

Which candidate instruction presets are safe to ship in the "Start from..." menu? Three of five. Slack, Keep my wording and Code comments ship. Email-ready and Short and direct are dropped. A preset ships only if at least 90 percent of its takes pass the guard and the accepted outputs visibly follow the instruction.

**Read the caveat first.** Twelve to sixteen takes per preset is a small set, so one guard rejection moves a preset by six to eight points. This shows which instruction texts the guard and Gemma 4 E4B hold together on realistic takes. It isn't a measure of how well a preset works on all speech.

## What was measured

- Model: `gemma-4-e4b-it-4bit`, the Thorough model, through `SmartCleanup` at the Thorough level, with each preset's text passed as the instructions.
- Takes: the same general set for every preset, drawn from `instruction-cases.json` and the smart cases (a request with a name and a date, a counted list, a negation, a spoken correction, dollars spoken as words, a spoken greeting and sign-off, filler-heavy speech), plus a few new ones for names, numbers and negations. Code comments has its own set of code-flavored takes (a return value, a warning, a TODO, a number with a limit, a name).
- Accepted: the guard let the model's text through (outcome `ok`). A guard-rejected take falls back to Basic, which is safe but means the preset did nothing.
- Followed: read by hand over every accepted output, not a sample. The automatic `mustContain` checks only cover facts, not style.
- Machine: Apple M4 Pro, release build of `mouthtype-bench`, temp files only (`/tmp`), no app data touched.

Reproduce the shipped set with `swift build -c release --product mouthtype-bench`, then `.build/release/mouthtype-bench clean --smart medium --file Tests/Fixtures/instruction-preset-cases.json --smart-timeout-ms 20000 --result /tmp/instruction-presets.json`. The gated test `instructionPresetsPassTheGuard` runs the same file.

## Results

Final text of each shipped preset, over the committed fixture:

| preset | takes | accepted | followed |
| --- | --- | --- | --- |
| Slack | 16 | 16 (100 percent) | yes, mildly |
| Keep my wording | 16 | 16 (100 percent) | yes |
| Code comments | 12 | 12 (100 percent) | yes |
| Email-ready | 16 | 14 (87.5 percent) | yes, but dropped on acceptance |
| Short and direct | 16 | 13 (81 percent) | barely, dropped |

Email-ready and Short and direct are the last rewrite's numbers. Rounds, each preset's text per round:

| round | takes | Slack | Keep my wording | Code comments | Email-ready | Short and direct |
| --- | --- | --- | --- | --- | --- | --- |
| 1, original texts | 12 (code: 12) | 11 of 12 | 12 of 12 | 12 of 12 | 9 of 12 | 10 of 12 |
| 2, rewrite 1 for email and short | 16 (code: 12) | 15 of 16 | 16 of 16 | 12 of 12 | 14 of 16 | 16 of 16 |
| 3, rewrite 2 for email and short, rewrite 1 for slack | 16 (code: 12) | 16 of 16 | 16 of 16 | 12 of 12 | 14 of 16 | 13 of 16 |

Round 2 added four takes (a spoken greeting and sign-off, a filler-heavy sentence, a gratitude take, a meeting with a name and a negation). Slack, Keep my wording and Code comments were re-run on the larger set unchanged.

## What each preset did

- **Slack.** `Write it like a quick Slack message: short and casual, with contractions. No greeting and no sign-off.` Adds contractions ("nothing's broken", "the meeting's Thursday", "Can't cover your shift") and turns "hello Dana" into "Hey Dana". The original wording ("Keep it short and casual, like a chat message...") was accepted 11 of 12 but changed almost nothing, so it was reworded to ask for contractions. Effect is mild on takes that are already casual.
- **Keep my wording.** `Keep my exact wording. Only fix punctuation, capitalization and grammar. Don't rephrase or reorder anything.` Keeps "So basically what I'm trying to say is that" and every hedge. On the counted-list take it still formatted a numbered list once (accepted, so the facts held).
- **Code comments.** `Write it as a code comment: terse, plain words. No trailing period on a one-line comment.` Produces `// returns null if user not found`, no trailing period, drops leading "we" and "this function". The model picked the `//` marker itself; it doesn't know the language, so edit the marker if the file isn't C-style. One take with no code meaning (a budget sentence) came back as plain text.
- **Email-ready (dropped).** Original text asked for a greeting, short paragraphs and a sign-off. The model ignored the greeting on 8 of 9 accepted takes. Rewrite 1 named the exact words ("Hi," then "Thanks,"); the model followed it on every accepted take but the guard rejected 2 of 16: a spoken "hello Dana ... best regards Scott" lost the name Dana, and a take with "maybe" lost the hedge (certainty check). Rewrite 2 told it to keep a spoken greeting and sign-off; same two rejections. 87.5 percent is under the 90 percent bar and both rewrite rounds are spent. It also writes a greeting with no name and a sign-off with no sender, which isn't ready to send.
- **Short and direct (dropped).** Original text accepted 10 of 12; the guard rejected the counted list (number check) and a take with "maybe" (certainty check). Rewrite 1 (keep hedges, no lists) was accepted 16 of 16 but trimmed almost nothing, so the outputs matched Keep my wording. Rewrite 2 asked for lead-ins like "so basically" to be dropped, and the model then dropped "probably" ("We should look at the logs again"), which the guard rejected. Rewrites that trim hard trip the certainty check, and rewrites that don't trim do nothing, so it's dropped.

## Takeaways

- Instructions that only add or reshape layout pass. Instructions that remove words (trimming, dropping a greeting that carries a name) are where the guard rejects, by design, because the removed words are often a name, a number or a hedge.
- A counted list rewritten as bullets still trips the number check ("three things" becomes a list with no "three"). That was already known from the earlier instruction cases and isn't something a preset can fix.
