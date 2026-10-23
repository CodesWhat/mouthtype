# Thorough cleanup by language, October 2026

Does Thorough (Gemma 4 E4B) clean dictation in languages other than English without translating it or mangling it? Short answer: on the fixture set, yes for the eight tier-1 languages, so Thorough ships for German, Spanish, French, Italian, Portuguese, Dutch, Polish and Russian. Fast stays English only. Every other language skips the model pass (reason "language") and gets the Basic output until it has been measured.

**Read the caveat first.** The fixtures are small (9 to 12 takes per tier-1 language) and mostly already-clean text as Parakeet v3 writes it, plus three messy takes per tier-1 language (fillers and a repeated word, a spoken self-correction, an unpunctuated counted list). At that size a 95 percent accepted gate means no take can fail, so this shows the prompt, the guard and the language check hold together on realistic text. It isn't an accuracy claim for the long tail of real speech.

## What was measured

- Model: `gemma-4-e4b-it-4bit`, the Thorough model, through `SmartCleanup` at the Thorough level with the non-English prompt (the language line last, no English-only rules) and the neutral guard checks.
- Order: the deterministic pipeline for the take's language first (English-only stages off), then the model, as the app runs it. The blend fixture runs with `Wir haben einen ` before the cursor.
- Accepted: the guard let the model's text through (outcome `ok`).
- Language-preserved: `NLLanguageRecognizer`, constrained to the take's language and English, reads the model's own output as the take's language. Output under three words counts as preserved.
- Edited by the model: its output differs from the deterministic text.
- Content-word retention: share of the input's words over two letters that the output keeps.
- Latency: milliseconds per word of the whole `SmartCleanup.run`, median and nearest-rank p95 over the takes. The p95 of a language with 10 takes is its slowest take, and the shortest takes (two words) carry the model's fixed cost, so read the median.
- Gate: tier-1 languages at 95 percent accepted and 100 percent language-preserved.
- Machine: Apple M4 Pro, macOS 26.6.2, release build of `mouthtype-bench` at `239e4f3` plus the chunk F changes. A debug build is about twice as slow and times out the longest takes in every language, English included, so timings from one aren't comparable.

Reproduce with `swift build -c release --product mouthtype-bench`, then `.build/release/mouthtype-bench language-cleanup --report /tmp/language-cleanup.md --out /tmp/language-cleanup.json`. Add `--languages de,ru` for a subset. The command exits non-zero when a tier-1 language misses the gate.

## Results

| language | n | accepted | language-preserved | edited by the model | content-word retention | p50 ms/word | p95 ms/word | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| cs | 4 | 100 percent | 100 percent | 0 of 4 | 100 percent | 43 | 178 | n/a |
| da | 4 | 100 percent | 100 percent | 0 of 4 | 100 percent | 37 | 218 | n/a |
| de | 12 | 100 percent | 100 percent | 2 of 12 | 100 percent | 29 | 442 | pass |
| el | 4 | 100 percent | 100 percent | 1 of 4 | 96 percent | 50 | 65 | n/a |
| en | 9 | 100 percent | 100 percent | 5 of 9 | 98 percent | 29 | 117 | n/a |
| es | 11 | 100 percent | 100 percent | 2 of 11 | 99 percent | 25 | 42 | pass |
| fr | 10 | 100 percent | 100 percent | 3 of 10 | 99 percent | 27 | 48 | pass |
| it | 10 | 100 percent | 100 percent | 2 of 10 | 99 percent | 28 | 152 | pass |
| nl | 10 | 100 percent | 100 percent | 2 of 10 | 99 percent | 29 | 116 | pass |
| pl | 11 | 100 percent | 100 percent | 3 of 11 | 99 percent | 39 | 171 | pass |
| pt | 10 | 100 percent | 100 percent | 2 of 10 | 99 percent | 25 | 138 | pass |
| ru | 10 | 100 percent | 100 percent | 3 of 10 | 100 percent | 32 | 128 | pass |
| uk | 6 | 100 percent | 100 percent | 1 of 6 | 100 percent | 40 | 124 | n/a |

Median latency per word against English:

- cs: 1.48x
- da: 1.27x
- de: 0.99x
- el: 1.73x
- es: 0.85x
- fr: 0.93x
- it: 0.95x
- nl: 1.00x
- pl: 1.33x
- pt: 0.88x
- ru: 1.10x
- uk: 1.39x

Ship gate: PASS for de, es, fr, it, pt, nl, pl and ru. Greek, Ukrainian, Czech and Danish also passed their (4 to 6 take) sets, but the gate names the tier-1 languages, so they aren't in the supported set yet.

## What it decided

- `SmartLanguageSupport.thoroughLanguages` holds the eight passing languages. Thorough for any other non-English language is skipped with the reason "language". If a later run fails the gate for one of them, remove it from that set and the app stops using the model for it.
- The time budget scales with a per-language multiplier, from the median ratio above rounded up to a quarter: Polish, Czech, Ukrainian and Danish 1.5, Russian 1.25, Greek 1.75, everything else 1. Finnish, Hungarian, Estonian and the rest weren't measured and don't reach the model.
- The correction pass, correction commas and name joining read English cues, so they are off outside English. A spoken self-correction in another language comes back as dictated (the messy takes above keep "nein warte, bis Mittwoch"), which is the safe outcome and a known limit.
- Swearing removal is English only, so the Formal tone adds nothing to the non-English prompt.

## Not covered

Real speech, longer takes, mixed-language takes, the languages outside tier 1, and the quality of Fast (S1-mini is English only by its model card and is never run on other languages).
