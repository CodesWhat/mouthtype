# Contextual name and literal preservation, 2026-10-15

Nearby names can help choose a spelling, but must not rewrite an address, path or inline code. At the baseline, Thorough changed `jon@example.com` to `john@example.com`, `jon/reports` to `John/reports`, and backticked `merry` to Mary. The new guard rejects these edits and delivers the original transcript. It permits an immediately adjacent explicit correction when the replacement literal survives.

Baseline: `67c0c5846d8ee042e96e844f4ec62893a8a86ed1`. Guard: `78f82199206c6f16f600176eabe430ecdedc4a72`. Both runs use the debug bench, cached local models and the same 40 synthetic cases. These are accuracy replays, not latency measurements or live paste tests. Every case requires exact casing. Light and Medium are reported separately.

| Model | Level | Baseline | Guard | Literal cases before / after |
| --- | --- | --- | --- | --- |
| superwhisper-s1-mini | light | 26/40 | 26/40 | 3/3 → 3/3 |
| superwhisper-s1-mini | medium | 26/40 | 26/40 | 3/3 → 3/3 |
| gemma-4-e4b-it-4bit | light | 31/40 | 34/40 | 0/3 → 3/3 |
| gemma-4-e4b-it-4bit | medium | 31/40 | 34/40 | 0/3 → 3/3 |

The earlier private 18-case comparison omitted `caseSensitive`; its 15/18 and 18/18 scores did not establish correct casing. This fresh strict baseline passes 12/18 with Fast and 16/18 with Thorough on those original cases. The added cases cover more soundalikes, ordinary verbs, explicit surnames, multiple listed spellings and literal text.

General name selection is still unresolved. Remaining failures include ordinary Reed/reed casing, quoted labels, names in non-person context, and a model proposal that appends a surname. A rejected rewrite can also preserve the original words while missing the requested name casing. The full fixture deliberately retains those failures; this guard is not a general name-matching solution.

Validation: 56 focused tests pass, including literal mutations at both cleanup levels, the two model paths, ordinary punctuation and explicit corrections. The full suite passes 1,077 tests (569 Mac, 492 Core, 16 Fn), including cached real models and opt-in saved-audio fixtures. An unrelated later correction cue cannot excuse a lost literal.

The signed installed app remains at the baseline. No app restart, desktop focus, generated key input or live paste test was performed. No new pronunciation data or dependency is shipped.

[Cases](../../Tests/Fixtures/context-name-selection.json) · [Delivered outputs and checks](2026-10-15-name-literals.json)
