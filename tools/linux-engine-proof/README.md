# Linux engine proof

This is a standalone, headless experiment for supplied fixtures. It does not change the Mac package, start recording, register shortcuts, deliver text, download models, or provide a Linux app. It compares **raw engine output**, not the app's complete SmartCleanup pipeline. A bounded Linux CPU inference result is recorded below; Arch desktop acceptance remains pending.

The runtime adapters use Parakeet TDT 0.6B v3 INT8 through sherpa-onnx CPU and **S1-mini by Superwhisper** Q4_K_M through a managed llama.cpp CPU server. One worker remains resident for each task's fixtures. Speech and cleanup run sequentially to avoid holding both models in memory. Every child belongs to the worker's process group and is stopped on completion, interruption, startup failure, deadline, or cancellation. The server listens only on `127.0.0.1`, has a unique per-run model alias checked against its model API, and is never left running as a daemon. No fixture text is placed in command arguments or application logs.

## Checks without models

From the repository root, run `python3 -W error::ResourceWarning -m unittest discover -s tools/linux-engine-proof -p 'test_*.py'`.

These tests use temporary synthetic WAVs and fake engine processes, including a real local HTTP round trip. They check resident reuse, Unicode and empty results, mismatches, model digests, runtime version checks, exact S1 prompt/control settings, process crashes, blocked writes, deadlines, cancellation, and process/server cleanup. They do not install inference libraries or fetch weights. The narrowly scoped workflow runs the same checks on Ubuntu with Python 3.12 and an Arch container with its current signed Python package. Both jobs have read-only repository access. A green job establishes headless orchestration behavior in that recorded userland, not model accuracy, inference performance, desktop support, or general Arch compatibility.

## Runtime and artifact preparation

Use a dedicated Linux x86_64 machine or runner with Python 3.12, a virtual environment, Git, CMake, and a C++ compiler. Ubuntu's relevant packages are `python3.12-venv`, `git`, `cmake`, and `build-essential`. On Arch, provide an available Python 3.12 environment separately if the rolling system interpreter has moved ahead; `base-devel`, `git`, and `cmake` cover the C++ build prerequisites. Record the actual distribution/package snapshot. Package names are prerequisites, not evidence that either target has been tested. Nothing here changes system packages.

Install `requirements.txt` into that local virtual environment. It pins both `sherpa-onnx` and its `sherpa-onnx-core` dependency at 1.13.8. Build `llama-server` from the full llama.cpp revision in `pins.json`, following the [official CPU build instructions](https://github.com/ggml-org/llama.cpp/blob/6420cf5dd588c68e48657a0bbd82bb3bd5ac7209/docs/build.md). For a CPU-only reproducible experiment, configure `GGML_CUDA=OFF`, `GGML_VULKAN=OFF`, `GGML_NATIVE=OFF`, and `LLAMA_CURL=OFF`, then build the `llama-server` target. Keep its shared libraries with the binary. The worker checks the embedded Git revision and records the binary SHA-256. No GPU speed or portability is inferred from this build choice.

`pins.json` records immutable runtime revisions, publisher model provenance, quantization, license links, and upstream artifact digests. Its Parakeet archive digest comes from GitHub release asset 283097583; the S1 GGUF digest comes from the publisher's Hugging Face LFS metadata at the recorded revision. Fetch those exact assets separately when model download is coordinated. Keep the Parakeet archive alongside its unpacked directory. This harness never downloads them automatically.

Verify local assets and create an ignored config with one command, replacing local paths as needed: `python3 tools/linux-engine-proof/prepare.py --parakeet-archive /local/parakeet.tar.bz2 --parakeet-dir /local/parakeet --s1 /local/s1-mini-q4_k_m.gguf --server /local/llama-server --output .planning/linux-proof-config.json`.

Either artifact pair can be omitted to prepare speech only or cleanup only. Preparation rejects mismatched published archive/GGUF hashes, compares each extracted speech file against the verified archive, and hashes the runtime binary and individual model files. It reads selected regular archive members without extracting anything. Existing output files are preserved. The run checks those hashes again before starting workers.

Runtime setup and artifact preparation are explicit operator actions, separate from the no-model checks. One coordinated remote CPU proof installed the pinned stack and downloaded the verified models on a disposable hosted runner; routine no-model checks still fetch no weights.

## Run supplied fixtures

The existing synthetic cleanup benchmark can be compared directly: `bash tools/linux-engine-proof/run-proof.sh --config .planning/linux-proof-config.json --cleanup Sources/mouthtype-bench/Fixtures/cleanup-cases.json --output .planning/linux-proof-results.json`.

The script requires Linux. `MOUTHTYPE_PROOF_PYTHON` can select the virtual environment's Python executable. `proof.py` itself can run host orchestration experiments, whose report records the real operating system and `linux_runtime` flag. Never present a macOS result as Linux proof.

Speech fixtures are a JSON array of objects containing a unique `id`, `wav`, and `expected`. WAV paths resolve relative to the fixture file. Only uncompressed 16 kHz mono PCM16 WAV files are accepted, with a ten-minute cap. Use synthetic or explicitly approved recordings and expected transcripts. Add `--speech .planning/approved-speech-cases.json` to compare them. An expected empty string is valid for a silence/noise fixture. The harness does not supply or publish private recordings.

Cleanup fixtures contain a unique `id`, `input`, and `expected` or the existing benchmark's `reference`. Empty expected text is valid. Existing `mustContain`, `mustNotContain`, and `maxLengthRatio` assertions are also evaluated; the report separately lists exact-reference and constraint failures. Case-sensitive exact comparison is intentional and can flag punctuation/formatting differences. A mismatch is evidence to inspect, not a claim that the backend is unusable. Cleanup vocabulary and nearby context fields are not applied by this raw S1 adapter.

Defaults allow 120 seconds for cold startup and 30 seconds per fixture. `--startup-seconds` and `--request-seconds` accept finite positive limits. Pressing Control+C requests cancellation. `--cancel-after-seconds 2` provides a repeatable cancellation probe without microphone or desktop activity. Cancellation or a deadline kills the task's worker/server; later fixtures are recorded as unavailable instead of reusing partial state or retrying invisibly. Repeat a run with a new result path to check recovery. No existing result is overwritten.

Speech fixture identity uses audio content and expectations rather than absolute host paths, so the same supplied fixture can be compared across machines. Reports include full expected/actual output, exact fixture identity, actual OS/architecture/kernel/Python, runtime revision, local artifact hashes and provenance, cold load duration, resident request number, per-request wall duration, outcomes, and available peak memory. Keep reports under `.planning/` because supplied transcripts may be private. Standard output prints only counts and the chosen result path. Exit 0 means every exact/constraint check passed, 1 means a mismatch/deadline/cancel/engine failure occurred, and 2 means configuration or artifact preparation was unavailable. Worker errors record their exception class without dumping private text.

On Linux, worker peak RSS comes from `getrusage`; server peak RSS comes from `/proc/PID/status` when readable. The combined field adds each process's high-water mark, which is an upper-bound sum rather than a simultaneous process-tree measurement. Missing server memory is `null`, not zero. First-output latency is `null` because this adapter returns complete non-streaming results. Cold file-cache state, CPU model, RAM, thermal state, package snapshot, and power settings still belong in the operator's environment receipt.

## Recorded Linux checkpoint

The [bounded synthetic CPU run](https://github.com/CodesWhat/mouthtype/actions/runs/38985174917) on Ubuntu 24.04 x86_64 loaded both pinned engines, reached ready, and completed all six fixtures without errors, deadlines, or remaining owned processes. Both generated spoken WAVs and the synthetic silence case matched exactly. Two of three cleanup cases matched; `selfcorrect-01` expected “Let's meet on Wednesday at three.” and returned “Let's meet on Wednesday at 3.” Overall exact comparison was 5/6. The job remained failed for that unchanged exact assertion, while the separate assessment recorded successful real-runtime completion. No comparator, expected value, or default was changed to obtain a green result.

The [Ubuntu and Arch-userland checks](https://github.com/CodesWhat/mouthtype/actions/runs/38984542651) also passed all 21 no-model orchestration tests in each environment. Those checks exercise fake engines and process management; the actual model run above used the pinned native runtimes and verified weights on Ubuntu only.

## What remains unproved

Representative human-recording quality, broader silence/noise behavior, repeatable cold/warm performance and memory measurements, cancellation during native inference, and recovery after a real runtime failure need further Linux acceptance. The sherpa adapter does not add FluidAudio VAD or its English hinting, and it does not invent word confidence/timing data. The S1 adapter preserves the publisher system prompt, the Mac benchmark's semi-formal/lists/general controls, disabled thinking through the chat template, and greedy decoding. GGUF Q4_K_M output is not numerically identical to the Mac BF16 model. Full SmartCleanup guards, saved spelling, contextual corrections, and app delivery remain outside this proof.

Ubuntu or Arch headless results cannot establish general Arch support, global shortcut behavior, Wayland delivery, clipboard ownership, audio routing, or a desktop frontend. Those acceptance rows remain separate.

## Arch headless CI scope and provenance

The additional job uses the [official Arch Linux base image](https://hub.docker.com/_/archlinux), dated tag `base-20261011.0.609700`, pinned to registry index digest `sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0`. Its Linux amd64 manifest is `sha256:363129b67b2bc6c5a634f8fb4961a7e2eba213a2ec075d159127b1260290a722`. The [official image listing](https://github.com/docker-library/official-images/blob/master/library/archlinux) identifies Arch's `archlinux-docker` source revision `1e7d9a2d495ffe76934a775b6bd68ac892a14c1b`, tag `v20261011.0.609700`, `Dockerfile.base`. Registry metadata and official provenance were inspected on 2026-10-16 without pulling or starting any local container.

Docker `--init` handles orphan reaping while the existing tests still require owned descendants to disappear. The remote, ephemeral job performs a normal full `pacman -Syu` upgrade with only Git and Python requested, following the official image's rolling-update guidance. Pacman's normal signature verification remains in force; no signature setting, privilege, repository source, or key trust is weakened. It records `/etc/os-release`, kernel/architecture, Python/glibc versions, exact Git/Python/glibc/pacman/keyring package versions, and the effective signature policy before running the unchanged no-model tests. The dated image pins the starting filesystem; the rolling signed package transaction is identified by those actual versions rather than presented as an immutable package snapshot.

The job runs an Arch userland on a hosted Ubuntu x86_64 kernel, has `contents: read`, persists no Git credentials, uses no secrets/models, and has a ten-minute deadline. No Swift toolchain or inference package is installed. The completed, fetched run linked above establishes the narrow Arch-userland orchestration result. It does not prove Arch kernel integration, audio, shortcuts, desktop paste, model inference, packaging, or a Linux release.

## Primary sources

- [sherpa Parakeet v3 model guide](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html)
- [Pinned sherpa Python recognizer](https://github.com/k2-fsa/sherpa-onnx/blob/11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf/sherpa-onnx/python/sherpa_onnx/offline_recognizer.py)
- [Publisher S1 GGUF prompt, decoding and template instructions](https://huggingface.co/superwhisper/s1-mini-GGUF/blob/34add00a48a2e5d24e5a4ee5405a99620a3a240c/README.md)
- [Pinned llama-server API and command options](https://github.com/ggml-org/llama.cpp/blob/6420cf5dd588c68e48657a0bbd82bb3bd5ac7209/tools/server/README.md)
