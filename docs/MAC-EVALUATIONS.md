# Mac daily-use evaluations

A synthetic speech evaluation of the Mac recognition path. It needs macOS, an installed speech voice, `ffmpeg` and the normal Swift build dependencies.

## Run it

1. Use the app's normal model setup first. The worker uses the same speech-model preparation path as the benchmark, which can fetch missing assets.
2. Run `python3 scripts/evaluate-mac-daily-use.py --output-dir build/daily-use-eval-01` from the repo. The output directory must be new.
3. The script builds `mouthtype-bench` unless `--bench-path` names an existing binary. It creates synthetic speech with macOS's installed Samantha voice, converts it with `ffmpeg`, and runs the existing Parakeet engine worker with the English hint used by the Mac app. The worker keeps automatic language detection as its default for other callers.

This evaluation doesn't record the microphone, play speech through the speakers, change app preferences or drive a text field.

## The corpus

The corpus has four clips.

| Clip | What it is |
| --- | --- |
| Short clean | A short clean reference from `Tests/Fixtures/daily-use-speech.json`. |
| Noise 20 dB | The same waveform with seeded noise at 20 dB global RMS SNR. |
| Noise 10 dB | The same waveform with seeded noise at 10 dB global RMS SNR. |
| Extended | A long recording ending with a distinct checkpoint. The default repeats its reference paragraph six times. Actual audio duration is recorded, not inferred from the clip's name. |

Noise is normalized before mixing. The manifest records requested and measured SNR, clipped sample count and seed. If clipping changes the achieved SNR, use the measured value. Silence and nonfinite SNR aren't valid noise inputs.

## What it records

Each clip gets one warmup and three timed recognition runs by default. `recognition.json` contains recognized text, word-error counts, durations and per-run latency from the existing worker. Word-error counts use the final timed hypothesis for each clip.

> [!NOTE]
> The median and p95 describe a few samples, not a production tail-latency guarantee. Timings exclude key-down, microphone startup, cleanup and insertion. Check the long reference's final checkpoint as well as its word-error rate.

`manifest.json` records source HEAD, macOS/Python versions, voice, speech rate, run count, audio/reference hashes, noise parameters and benchmark binary hash. When an existing binary is supplied, the manifest records that it wasn't built by this invocation; its hash doesn't establish source provenance by itself. Keep raw run output locally because the normal worker also reports model-cache paths.

## Options

Use `--prepare-only` to inspect the generated corpus without running recognition. `--voice`, `--rate`, `--runs` and `--long-repeats` make variations explicit. Use a new output directory for each comparison. The script bounds each synthesis/conversion, build and recognition subprocess and keeps their logs with the output.

## Related checks

Run the portable noise regressions with `python3 -m unittest discover -s Tests/BenchTests -p 'test_*.py'`. Existing Core real-model tests separately check cleanup literals, joined spellings, corrections and long read-through text.

> [!WARNING]
> These synthetic evaluations don't establish human, Bluetooth, sleep/clamshell, microphone-loss, quiet/restore or cross-app delivery acceptance. Record those with a coordinated native test separately.
