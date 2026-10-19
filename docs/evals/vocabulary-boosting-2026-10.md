# Vocabulary boosting evaluation, October 2026

Does recognition-time boosting of saved words help Parakeet, and does it break ordinary sentences? Short answer: with FluidAudio's default thresholds it helps names a lot and also rewrites ordinary words, so the app ships a stricter similarity floor. With that floor, exact-spelling recall on the tricky names rose from 33% to 56% and none of the ordinary sentences changed at 10, 50 or 200 saved words.

**Read the caveat first.** Every clip here is text-to-speech from macOS `say`. TTS is clean, evenly paced and has no room noise, so these recall numbers are optimistic and the false-positive numbers are probably optimistic too. Treat this as a regression check and a way to compare settings, not as an accuracy claim for human speech.

## What was measured

- Engine: `parakeet-tdt-v3` with the English hint, the shipped default. Boosting is FluidAudio 0.17.7's CTC keyword spotter (Parakeet CTC 110M) plus its constrained rescorer, run on the finished transcript. Spotter-anchored acoustic rescue is off.
- Clips: 50 sentences spoken by Samantha (en_US) and Daniel (en_GB), converted to 16 kHz mono WAV. 100 clips in all.
  - 25 `names` sentences with 90 spoken target spellings across 28 distinct terms (Siobhan, Nguyen, Kubernetes, Mouthtype, Ludacris, Saoirse, Niamh, Xiomara, Kowalczyk, Sockguard, Drydock, FluidAudio, WhisperKit, Zhang, Szymanski, Dhruv, Oluwaseun, Thibault and so on).
  - 25 `plain` sentences with ordinary words only, 50 clips with both voices.
- Vocabularies: for names, the 28 targets with no aliases. For the false-positive runs, 10, 50 and 200 names that never appear in any sentence (Aoife, Bronwyn, Wetherby, Prometheus, Lightstep and so on), with no aliases, so any change to a plain sentence is a wrong replacement.
- Recall: a target counts when its exact spelling, including case, appears as a whole word in the transcript.
- WER: word error rate against the reference sentence, lowercased with punctuation removed.
- Latency: `processingSeconds` from the engine call, which includes the VAD pass, Parakeet and the rescoring. Median of three timed passes per clip, then the median and p95 of the per-clip difference from the unboosted run.
- Machine: Apple M4 Pro, macOS 26.6.2, release build of `mouthtype-bench` at the branch head.

Reproduce with `python3 scripts/boost-eval-clips.py /tmp/mouthtype-boost-eval`, `swift build -c release --product mouthtype-bench`, `.build/release/mouthtype-bench boost-eval`, then `python3 -I scripts/boost-eval-report.py /tmp/mouthtype-boost-eval/results.json`. The `--min-similarity`, `--min-combined`, `--taper-pivot` and `--min-term-length` options on `boost-eval` set the rescorer thresholds for a run.

## Results at the shipped setting (minimum similarity 0.70)

| | Boosting off | Boosting on |
| --- | --- | --- |
| Names recall, all clips | 30 of 90 (33%) | 50 of 90 (56%) |
| Names recall, Samantha | 19 of 45 (42%) | 29 of 45 (64%) |
| Names recall, Daniel | 11 of 45 (24%) | 21 of 45 (47%) |
| Names WER | 20.0% | 13.1% |
| Plain WER | 1.3% | 1.3% at 10, 50 and 200 terms |

Wrong replacements on the 50 plain clips, vocabulary of never-spoken names:

| Vocabulary size | Clips changed | Distractor words inserted | WER |
| --- | --- | --- | --- |
| 10 | 0 of 50 | 0 | 1.3% |
| 50 | 0 of 50 | 0 | 1.3% |
| 200 | 0 of 50 | 0 | 1.3% |

Added time per clip over the 43 ms median of the unboosted run: 113 ms at 10 terms, 132 ms at 50 (121 ms with the 28 names), 210 ms at 200 (p95 232 ms, max 237 ms). The app gives rescoring 1.5 s before it keeps the plain transcript.

Memory: the CTC model added about 9 MB of physical footprint (60 to 69 MB) and about 9 MB of resident size (112 to 121 MB) after load, and the process footprint peaked at 79 MB across the runs. CoreML keeps most model weight outside the process footprint, so Activity Monitor can show more than this; the figures are the process's own accounting. The first load downloaded about 100 MB and took 19.2 s including Core ML compilation on this connection; later loads from the cache took 0.2 s.

## Before tightening, with FluidAudio's defaults (0.52)

The first full run used the library defaults. Names recall was better and ordinary sentences were not safe:

| | Result |
| --- | --- |
| Names recall | 61 of 90 (68%) |
| Names WER | 10.2% |
| Plain clips changed, 10 terms | 8 of 50 (WER 2.9%) |
| Plain clips changed, 50 terms | 14 of 50 (WER 4.6%) |
| Plain clips changed, 200 terms | 14 of 50 (WER 5.0%) |

Examples: "the broken door" became "the Bronwyn door", "He found a mistake" became "He Jorund a mistake", "The car needs a new battery" became "The car Nerys a new battery", and "the dashboard finally works" became "The Gaspard Niall works". That is far above the bar of one wrong replacement per 50 sentences at 50 terms, so the thresholds were tightened and the run repeated.

## Threshold sweep

Same clips, 50-term plain vocabulary for the false-positive column, names vocabulary for recall. "Similarity" is the rescorer's minimum string similarity; where the combined-confidence column differs from 0.54 it was raised with it.

| Similarity | Combined confidence | Names recall | Plain clips changed (50 terms) |
| --- | --- | --- | --- |
| 0.52 (library default) | 0.54 | 68% | 14 of 50 |
| 0.65 | 0.65 | 62% | 2 of 50 |
| 0.65 with short-term boost taper (pivot 5) | 0.65 | 62% | 2 of 50 |
| 0.70 | 0.54 | 56% | 0 of 50 |
| 0.70 | 0.70 | 56% | 0 of 50 |
| 0.75 | 0.75 | 54% | 0 of 50 |
| 0.85 | 0.85 | 50% | 0 of 50 |

0.70 is the first setting with no wrong replacements, and recall barely moves above it, so 0.70 ships with the default combined confidence. The short-term taper changed nothing on this set. Recall at 0.70 is still 23 points above plain Parakeet.

## What boosting did not fix

31 of the 50 names clips still miss at least one target at the shipped setting. The misses are mostly names Parakeet hears as an ordinary word or a different name entirely ("Dr. Wynne" for Doctor Nguyen, "Sersha" for Saoirse, "Drove" for Dhruv). Those need a saved heard form to match, which is why the app passes the heard spellings from the dictionary as aliases. This run used no aliases, so it measures the hard case. The 50-term names vocabulary (targets plus 22 distractors) scored the same as the targets alone.

## Limits

- TTS only, two voices, English only, about 25 sentences per group. One of the 90 targets is about one point of recall, so differences of a few points are noise at this size.
- The CTC model is English. Boosting on the multilingual v3 engine helps English names and does nothing useful for other languages.
- Rescoring uses the same audio the engine just transcribed, trimmed of leading and trailing silence.
- The pinned Hugging Face revision for the CTC model is not set because FluidAudio's `CtcModels` has no revision parameter in 0.17.7. The repo head when this was run was `accdafd8cf8a2ff1cabe3c11e54416b405d409aa` (`FluidInference/parakeet-ctc-110m-coreml`, CC BY 4.0).
