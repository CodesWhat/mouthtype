# Long read-through deadline, 2026-10-14

A live 157-word practice take hit the four-second cleanup deadline at 4,109 ms. The basic fallback preserved the text but also preserved deliberate repeated starts. Nearby 136–158-word takes completed in roughly 3.1–3.8 seconds. The model can handle the passage, but the deadline had little headroom.

General-model cleanup now gets 1,200 ms plus 30 ms per word, capped at 12 seconds. A focused correction pass shares a doubled allowance within that same ceiling. The native cleaner's 400 ms plus 12 ms per word, 2.5-second ceiling and explicit diagnostic overrides are unchanged. A result still returns as soon as it finishes; the deadline is not a delay.

The regression uses the supplied 154-word text passage, checks that repeated starts disappear and requires the statements about hesitation, preserving meaning, simple cases and meaningful uses of “like” to survive. It passed at Light under both the previous release budget (3,285 ms) and the new one (3,250 ms). This warm text replay does not reproduce every live timing condition. The deterministic timing regression separately demonstrates that a valid 4.2-second model response was cut off before the change and is accepted afterward.

All 1,049 tests pass: 561 Mac, 472 Core and 16 Fn. The Core suite includes the long passage through the real cached model; that debug-host regression uses an explicit ten-second diagnostic budget. The release check uses the production word-scaled budget. Proposed and delivered text are in the adjacent JSON. No live microphone or paste test was repeated for this follow-up.

Reproduce the production check with `swift run -c release mouthtype-bench clean --smart light --file Tests/Fixtures/long-read-through.json`. Cached Gemma 4 E4B is required. This is a single-passage timing/meaning regression, not a general accuracy benchmark. The installed app is unchanged while the user practices.
