# Cleanup model eval: LFM3 1.7B and MTP speculative decoding, 2026-11-26

Raw report: `docs/benchmarks/2026-11-26-lfm3-cleanup-eval.md` (and `.json`). Same 75 cleanup bench cases, 2 timed runs each, greedy decoding, the shared cleanup prompt. Apple M4 Pro, release build, mlx-swift-lm 3.33.0.

**Latency is under load.** Other builds were running (load average 70 to 120 during the run), so treat the millisecond numbers as relative and the pass rates as the reliable result.

| Model | Pass rate | Short total p50 | Long total p50 | Tokens/s | Size |
| --- | ---: | ---: | ---: | ---: | ---: |
| LFM3 1.7B 4-bit | 29% | 129 ms | 3016 ms | 178 | 945 MB |
| Qwen3 4B Instruct 2507 4-bit | 80% | 237 ms | 3954 ms | 74 | 2172 MB |
| Gemma 4 E4B 4-bit | 83% | 297 ms | 5462 ms | 65 | 4939 MB |

## LFM3 1.7B

About 2.4x the decode speed of Qwen3 4B, but it fails 53 of 75 cases. The common failure is that it echoes the input and then appends a second cleaned copy, or hits the output length limit and returns nothing (self-correction 0%, custom vocabulary 0%, run-on 0%). It only passes "already clean" and very short inputs. Thinking was switched off through the chat template (`enable_thinking: false`) for this run. It is not a candidate for cleanup with the current shared prompt.

License: LFM Open License v1.0, free under 10 million USD annual revenue. Shipping it would need a license decision from Scott, but with this quality result there is nothing to ship. The catalog entry is marked evaluation only and is not wired to any Fast or Thorough level.

## MTP speculative decoding (not measured)

mlx-swift-lm 3.33.0 has MTP drafters (`Gemma4AssistantDraftModel`, `Qwen35MTP`), but they live in the `MLXVLM` product, not `MLXLLM`. Using them means linking MLXVLM, loading the target through the VLM factory, downloading a separate Gemma 4 assistant drafter, and the Qwen path targets Qwen3.5, not the Qwen3-4B-Instruct-2507 we run. That is a loader change, not a bench change, and the task was measure-only, so no number was recorded. Follow-up: a separate slice that adds an MTP path to MLXCleaner for Gemma 4 E4B and benches it against the 65 tokens/s baseline above.

## Reproduce

```
swift build -c release --product mouthtype-bench
.build/release/mouthtype-bench cleanup --cleaners lfm3-1.7b-mlx-4bit,qwen3-4b-instruct-2507-4bit,gemma-4-e4b-it-4bit --runs 2 --out docs/benchmarks
```
