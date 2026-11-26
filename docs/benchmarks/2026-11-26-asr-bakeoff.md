# ASR bake-off, 2026-11-26 (MOD-2)

Apple M4 Pro, 48 GB, macOS 27.2.1, FluidAudio 0.18.3. Corpus: 119 clips (10 LibriSpeech test-clean "real", 9 synthetic daily-use clips, 50 custom plain sentences, 50 custom tricky-name sentences), built by `scripts/bakeoff-corpus.py`. Run with `--english-hint`, 3 timed runs per clip, one warm-up. Full per-clip output: `2026-11-26-asr-bakeoff-full.md` and `.json`.

Latency was measured while other parallel builds were running on the machine. Treat the millisecond and RTFx numbers as under load and noisy; WER is the reliable column.

| Engine | WER all (95/90/101 edits of 2186 words) | real | synthetic | custom plain | custom names | Median ms (all clips, under load) | Model MB |
|---|---|---|---|---|---|---|---|
| Parakeet TDT 0.6B v3 (shipped default) | 4.35% | 0.40% | 0.38% | 1.26% | 20.00% | 477 | 461 |
| Parakeet Ultra 0.6B | 4.12% | 0.40% | 0.38% | 1.47% | 18.57% | 412 | 603 |
| Nemotron Unified ASR 0.6B (offline, en) | 4.62% | 0.40% | 0.29% | 1.47% | 21.43% | 423 | 597 |

Not measured: Fluid Speech Mini (EN). The pinned FluidAudio 0.18.3 has no `AsrModelVersion` or manager for it, so there is nothing to load without a FluidAudio bump. Nemotron streaming (live preview) was not measured either; only its offline pass.

## Read

The gaps are a handful of edits (Ultra beats v3 by 5 edits, Nemotron loses by 6) on a small set, mostly on synthetic tricky-name clips that no model gets right without vocabulary boosting. On the real LibriSpeech clips all three tie at one edit. No model wins on our clips by a margin that justifies a model swap, so the default stays Parakeet v3. Ultra is the only candidate worth re-checking if a larger real-speech corpus becomes available.
