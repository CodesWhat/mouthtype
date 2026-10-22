# Security controls and limits

Mouthtype is a single-user local dictation app, plus experimental Linux source and a static download website. Its meaningful boundaries are microphone capture, Accessibility-based text delivery, imported audio and local files, downloaded models, dependencies, and the signed release/update path. It isn't a hosted transcription service or a multi-tenant application. Developer benchmark modes can explicitly invoke a Claude CLI cleaner or judge; those modes can send their input to that service and must use synthetic data. The Mac app's Fast and Thorough cleanup paths use local models.

## Implemented controls

| Area | Control and evidence | Limit |
| --- | --- | --- |
| Local data | [Audio retention](AUDIO-RETENTION.md) limits completed audio while preserving recoverable takes. Data is stored in the user's Application Support directory. | Text history is indefinite. Mouthtype doesn't encrypt its database, recordings or backups. |
| Destination safety | [Insertion code](../Sources/MouthtypeMac/Insertion/) rechecks captured app/field state, refuses secure destinations and retains text for recovery. [Tests](../Tests/MouthtypeMacTests/TextInserterTests.swift) cover denied and changed destinations. | Accessibility behavior differs across apps. Clipboard reads don't prove insertion, and a partial paste may need manual repair. |
| Editor hints | [Editor hints](SETTINGS.md) are off by default, run only in VS Code, Cursor, Xcode and supported terminals, and read the window title, the existing cursor-text window and git-tracked file names of one project. [Tests](../Tests/MouthtypeMacTests/EditorHintsTests.swift) cover the off state and that names stay out of stored history. | File names can be sensitive. They go only to the local recognizer, in memory for one dictation, and are never written or logged. A wrong tab or stale title can supply another project's names. |
| Imported audio | [File transcription](FILE-TRANSCRIPTION.md) accepts one bounded supported file, preserves the original and requires explicit Copy or Save. | Decoding and inference use platform and dependency code. Resource bounds aren't proof that every parser defect is prevented. |
| Mac distribution | [Release helpers](../scripts/package-release.py) require exact release identity, sign with Developer ID, notarize and verify the package. [Public staging](../scripts/stage-public-release.py) preserves versioned assets and creates the matching source archive and signed Sparkle feed. | Notarization isn't a security audit. Fresh-install and in-app upgrade acceptance must be verified separately for the release. No SLSA level or reproducible-build claim is made. |
| Update delivery | [Updater](../Sources/MouthtypeMac/Updates/AppUpdater.swift) uses the configured HTTPS feed and Sparkle signing identity. Installation waits for active app work. | Network requests reveal ordinary request metadata to hosting providers. Release signing credentials remain a maintainer responsibility. |
| Dependencies | Swift and npm lockfiles preserve resolved inputs. [Dependabot](../.github/dependabot.yml) proposes weekly Swift, website and docs-site npm, and Actions updates to the active dev branch. Free repository vulnerability alerts are enabled. | Bot configuration needs to reach the default branch before scheduling. Updates and alert availability don't prove complete Swift advisory coverage. |
| CI authority | External Actions are SHA pinned, checkout credentials aren't persisted, jobs have timeouts and explicit permissions. Security checks need read access only. | Hosted runner labels and package repositories still evolve. Downloaded tool versions and container digests need separate maintenance. |
| Secret and workflow checks | [Security CI](../.github/workflows/security.yml) runs full-history Gitleaks with redaction, actionlint, zizmor and the portable release-helper tests. The real `ditto` archive integration test runs on Mac and is explicitly skipped on Linux. Tool archives are SHA-256 verified before execution. | Static checks have false negatives. Zizmor runs offline, so audits requiring GitHub API metadata aren't included. |
| Website dependencies | Security CI uses `npm audit --package-lock-only --audit-level=high`, including development and transitive packages. The separate [website workflow](../.github/workflows/website.yml) builds and runs browser checks. | Advisory databases aren't complete; a clean audit isn't a guarantee. This check doesn't scan the `apps/docs` lockfile, Swift dependencies or downloaded model files. |

## Linux client boundaries

The experimental [Linux client](../tools/linux-desktop/README.md) and [Omarchy plugin](../tools/omarchy-plugin/README.md) are source-only, with no supported desktop release. Physical Arch/Omarchy acceptance is still open, so these rows describe what the code does, not what a Linux machine has been shown to do.

| Area | Control and evidence | Limit |
| --- | --- | --- |
| Imported audio decode | [`imports.py`](../tools/linux-desktop/imports.py) accepts one regular file up to 512 MiB, identifies the container with `ffprobe` (20 second deadline, report over 1 MiB refused) and allows WAV, AIFF and M4A (any MP4-family container with an audio stream passes as M4A, and only its first audio stream is decoded) up to 10 minutes. `ffmpeg` runs with no stdin, audio stream only, `-t` of 601 seconds and a 120 second deadline, in its own process group that is killed on cancel or timeout. It writes a new 0600 file, and the decoded WAV must be 16 kHz mono PCM16 with at most 600 seconds of frames. | `ffprobe` and `ffmpeg` are the distro packages parsing untrusted files, with no extra sandbox. The bounds limit resources, not parser defects. |
| Local cleanup server | Fast and Thorough run a pinned `llama-server` ([`worker.py`](../tools/linux-engine-proof/worker.py)) bound to `127.0.0.1` on a free port, with the web UI off. Before each load the worker checks the server reports the pinned revision, the service hashes the server and model against `cleanup.json`, and the worker confirms the server answers under a per-launch model alias. The service skips rehashing a model file whose path, size, mtime, inode, device and ctime still match a recorded passing check, with a full re-hash at least daily; `MOUTHTYPE_VERIFY_FULL=1` forces it on every load. [`setup_cleanup.py`](../tools/linux-desktop/setup_cleanup.py) builds the pinned llama.cpp revision from source and verifies each GGUF's SHA-256 against [`pins.json`](../tools/linux-engine-proof/pins.json) before placing it. | The server has no API key, so any process on the machine, including another user's, can send it requests while it runs. The port is chosen by binding and releasing a free one, so another local process could take it first; the alias check catches that. A worker watches its parent and kills its whole process group (including `llama-server`) within about half a second if the service dies, SIGKILL included. It stays loopback-only. |
| Clipboard paste and restore | `paste` delivery is opt-in. It checks the captured window is still the active, unlocked one, copies the text with `wl-copy`, waits for the clipboard to hold it and sends the paste chord to that window through Hyprland's `send_shortcut` dispatcher, or through untargeted `wtype` only if both dispatcher forms fail and the captured window is still active. Terminals get Ctrl+Shift+V, and text with a line break is refused for them unless `allow_terminal_multiline` is set. The clipboard's offered types are read first. A text clipboard (1 MiB, 1 second read) is put back after `restore_delay_seconds` (default 1.5, range 0.1 to 30) only if the clipboard still holds the pasted text. An image, file list or text over 1 MiB is never overwritten: the take stays in recovery as `recover_only`. A clipboard marked with `x-kde-passwordManagerHint` is overwritten but not restored. Phrases that use `{clipboard}` read it the same way. | Window identity is not field identity: secure-field detection and insertion read-back aren't available, so `allow_unknown_secure_field` is required. Helper success means the paste was requested, not received. During that window the transcript sits on the clipboard where clipboard managers can read it. A target that reads the clipboard later than the restore delay still pastes the earlier content. |
| Default login service | The Omarchy plugin installer writes a user unit, `~/.config/systemd/user/mouthtype-linux.service`, wanted by and ordered after `graphical-session.target`, and enables it unless `--no-autostart` is passed or Launch at login is turned off from the menu. It refuses to overwrite a unit without the plugin's marker. The service runs as the user with no elevated rights and exits after 24 hours (`Restart=always` brings it back). Its socket is mode 0600 in a 0700 runtime directory. | The service restarts itself, so it can keep running across sessions until disabled. It records only after an explicit start command. |
| Hyprland bindings edit | Choosing a shortcut in the plugin edits `~/.config/hypr/bindings.lua` inside a marked block, copies the original to `bindings.lua.bak.mouthtype.<time>` first, reloads Hyprland and restores the backup if `hyprctl configerrors` reports a problem. It refuses a key Hyprland already binds. | Backups accumulate and aren't pruned. The plugin's hold binding goes through `control.py`, which orders press and release. The raw examples in `hyprland.lua`, `hyprland-legacy.conf` and the client README no longer include a bare hold binding, because independent press and release clients have no ordering (audit finding F14); the plugin's `control.py` pair is shown commented out instead. |

The maintainer reviews findings, dependency advisories, tool pins and shipped behavior. Don't send real transcripts or recordings to scanners or review tools as test fixtures.

## OpenSSF Scorecard

The [Scorecard workflow](../.github/workflows/security-scorecard.yml) runs the official Scorecard action on the default branch, weekly and on branch-protection changes. It publishes results to OpenSSF (the README badge reads them), uploads SARIF to code scanning and requests an OIDC credential for publishing only. It reports observations; no aggregate-score threshold substitutes for reviewing individual results and errors.

> [!NOTE]
> The report can still contain unavailable checks because of API permissions or platform support. A successful process exit or artifact upload doesn't make those checks pass.

Workflow credentials have read access to the repository's code, checks, actions, issues and pull requests, plus `security-events: write` and `id-token: write` on the Scorecard job only, without administrative permission.

> [!NOTE]
> `CODEOWNERS` requests review but doesn't enforce approval by itself. Required-review enforcement comes from the repository's branch protection or rulesets, which should be inspected directly rather than assumed.

Revisit the workflow's artifact retention and SARIF handling when the repository's visibility or plan changes. The reviewed development-branch release procedure remains the operating rule.

## Assurance case

This section ties Mouthtype's security requirements to its threat model, design principles and the evidence in this repository. It doesn't claim the app is safe against a compromised Mac. The implemented controls above and the remaining work below are the detail behind it.

### Security requirements

Mouthtype is meant to:

- keep recordings and transcripts on the user's Mac, with no audio sent over the network;
- deliver text only to the destination the user dictated into, and never into a secure field;
- fetch only pinned speech and cleanup models, and install only updates signed with the project's Sparkle key;
- request the narrowest macOS permissions that make dictation work; and
- ship builds that are signed, notarized and traceable to a reviewed release.

### Threat model and trust boundaries

The user is the only legitimate principal. Relevant threats are a malicious or malformed audio file, a changed upstream model repository or dependency, a tampered update or release asset, text landing in the wrong app or a password field, and a stray secret or real recording committed to the public repo. A person or process already controlling the user's account is out of scope, since it can read the same data and use the same Accessibility grant.

1. **Microphone to app.** macOS microphone permission, with the `com.apple.security.device.audio-input` entitlement in [Mouthtype.entitlements](../packaging/Mouthtype.entitlements). It's the only entitlement requested.
2. **App to destination app.** Accessibility-based insertion in [Insertion](../Sources/MouthtypeMac/Insertion/). [Delivery.swift](../Sources/MouthtypeMac/Insertion/Delivery.swift) discards the transcript when the focused field is secure or unreadable under secure input, and the focus is rechecked at delivery.
3. **Files and models to app.** Imported audio is bounded and treated as untrusted. Models come from Hugging Face at exact commits in [ModelPins](../Sources/MouthtypeCore/ModelPins.swift).
4. **App to update server.** Sparkle fetches the feed over HTTPS. [Info.plist](../packaging/Info.plist) sets `SUPublicEDKey` and `SURequireSignedFeed`, and [AppUpdater](../Sources/MouthtypeMac/Updates/AppUpdater.swift) checks the configured feed URL.
5. **Source to release.** Pull requests into the dev branch, Security CI, and the [release helpers](../scripts/package-release.py) that sign, notarize and verify.

### Secure design principles applied

- **Local first.** Transcription and the Fast and Thorough cleanup paths run on-device. The only network use in the app targets is model download and update checks. Neither carries audio or transcripts.
- **Least privilege.** One entitlement, microphone input. Accessibility and input-monitoring access are requested for the features that need them and nothing else. [build-app.sh](../scripts/build-app.sh) signs with the hardened runtime. Editor hints are off by default and read only the minimum from supported editors.
- **Fail safe.** When the destination changes, can't be verified or is secure, text isn't pasted. It's retained for recovery instead.
- **Data minimization.** [Audio retention](AUDIO-RETENTION.md) caps completed audio by age and size. Editor hint file names stay in memory for one dictation.
- **Supply-chain integrity.** Lockfiles, exact model commits, SHA-pinned Actions, signed and notarized releases, and a signed update feed.
- **Open review.** Source is public under GPL-3.0, with a private reporting channel in [SECURITY.md](../SECURITY.md).

### Countermeasures for common weakness classes

| Weakness class | Countermeasure | Evidence |
| --- | --- | --- |
| Sensitive data exposure | No audio upload, bounded retention, editor hint names never persisted or logged, redacted secret scanning in CI. | [AUDIO-RETENTION.md](AUDIO-RETENTION.md), [EditorHintsTests](../Tests/MouthtypeMacTests/EditorHintsTests.swift), [security.yml](../.github/workflows/security.yml) |
| Input into the wrong target | Focus snapshot recheck, secure-field refusal, recoverable retained text. | [Delivery.swift](../Sources/MouthtypeMac/Insertion/Delivery.swift), [TextInserterTests](../Tests/MouthtypeMacTests/TextInserterTests.swift) |
| Untrusted input parsing | Single bounded file, original preserved, results need explicit Copy or Save. Git file listings are capped at a byte limit. | [FILE-TRANSCRIPTION.md](FILE-TRANSCRIPTION.md), [ProjectFiles.swift](../Sources/MouthtypeCore/ProjectFiles.swift) |
| Tampered models or updates | Exact Hugging Face commit pins, bundled manifest check for offline cache adoption, EdDSA-signed feed required. | [ModelPins.swift](../Sources/MouthtypeCore/ModelPins.swift), [Info.plist](../packaging/Info.plist) |
| Vulnerable dependencies | Lockfiles, weekly Dependabot, npm audit at high severity. | [dependabot.yml](../.github/dependabot.yml), [security.yml](../.github/workflows/security.yml) |
| CI and workflow abuse | SHA-pinned Actions, non-persisted checkout credentials, explicit minimal permissions, actionlint and zizmor. | [workflows](../.github/workflows/) |
| Release tampering | Developer ID signing, hardened runtime, notarization, versioned public staging. | [package-release.py](../scripts/package-release.py), [stage-public-release.py](../scripts/stage-public-release.py) |

### Residual risks

- Accessibility access is broad. A compromised Mac, or malware running as the user, can use it the same way Mouthtype does.
- Text history, recordings and backups aren't encrypted, and text history has no expiry.
- Swift dependency advisories and downloaded model files aren't covered by automated scanning, and model files aren't hash-checked beyond what each library does.
- There's no hosted macOS CI lane, so Swift tests run by hand before release. No SBOM, provenance or reproducible-build claim is made.
- Destination apps differ in how they handle Accessibility and paste, so a partial insertion can still need manual repair.
- Developer benchmark modes can send input to a Claude CLI and must use synthetic data.

These are tracked in the remaining work below.

## Remaining assurance work

- [ ] Verify the first scheduled Dependabot processing and Scorecard report after the configuration reaches the default branch. Triage each error or finding, especially review, CI and protection detection.
- [x] MLX cleanup models are pinned to exact Hugging Face commits in `CleanerCatalog`, so a changed upstream repo isn't picked up by a fresh download.
- [x] Speech models are pinned to exact Hugging Face commits in [ModelPins](../Sources/MouthtypeCore/ModelPins.swift), the single place to read or bump them. Parakeet v3 (`FluidInference/parakeet-tdt-0.6b-v3-coreml` at `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`), Parakeet v2 (`FluidInference/parakeet-tdt-0.6b-v2-coreml` at `ee09c569f73759e6d44c9bd16766f477b2b36d39`), the CTC-110M vocabulary model (`FluidInference/parakeet-ctc-110m-coreml` at `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`), Silero VAD (`FluidInference/silero-vad-coreml` at `b419383c55c110e2c9271fa6ee0ea83d03c70d96`) and WhisperKit (`argmaxinc/whisperkit-coreml` at `0f63a7800b00dd0226abd051b906c246e1907482`). FluidAudio takes its pins through `ModelRegistry.revisionOverrides`. WhisperKit 1.1.1's `WhisperKit.download` has no revision parameter, so `WhisperModelFetch` runs the same variant lookup through `HubApiWrapper`, which does. Files are not hash-checked beyond what each library does. FluidAudio's fallback fetch of a missing Parakeet vocabulary JSON still resolves `main`, and a pin bump re-downloads the model once. Caches that predate the pins have no FluidAudio revision marker. FluidAudio adopts those itself when it can fetch the pinned file listing, so online they aren't re-downloaded. For a first launch with no network, `ModelCacheAdoption` checks the cache against a manifest bundled with the app (`ModelManifest.json`, generated at the pinned commits by `scripts/generate-model-manifest.py`) and writes the marker only if every required file is present and matches and no `.partial` file is left. Anything else is left for FluidAudio's own adoption or download.
- [ ] Establish automated Swift advisory coverage for the actual resolved packages and model supply chain. Until then, review upstream advisories and package changes before release; npm auditing doesn't cover them.
- [ ] Add a native Mac CI lane that actually compiles and runs meaningful Swift tests on the supported Apple Silicon/macOS toolchain. Existing Linux gesture tests and local Mac acceptance don't establish hosted Mac CI coverage.
  There's deliberately no macOS CI lane for now because of runner cost. `swift test` runs by hand before each release.
- [ ] Add dependency inventory/SBOM and build provenance only with exact source and artifact identity, then verify them. These aren't currently published guarantees.
- [ ] Keep physical installation, updates, permissions, microphone routing and destination-app acceptance in the release checks. Static scanner results don't replace them.

These are maintainer follow-ups, not claims that the repository has achieved a target Scorecard score or an OpenSSF Best Practices level above passing. See [SECURITY.md](../SECURITY.md) for supported releases and sensitive reporting.
