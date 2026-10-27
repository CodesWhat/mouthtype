# Security controls and limits

Mouthtype is a single-user local dictation app, plus experimental Linux source and a static download website. Its meaningful boundaries are microphone capture, Accessibility-based text delivery, imported audio and local files, downloaded models, dependencies, and the signed release/update path. It isn't a hosted transcription service or a multi-tenant application. Developer benchmark modes can explicitly invoke a Claude CLI cleaner or judge; those modes can send their input to that service and must use synthetic data. The Mac app's Fast and Thorough cleanup paths use local models.

## Implemented controls

| Area | Control and evidence | Limit |
| --- | --- | --- |
| Local data | [Audio retention](AUDIO-RETENTION.md) limits completed audio while preserving recoverable takes. Data is stored in the user's Application Support directory. | Text history is indefinite. Mouthtype doesn't encrypt its database, recordings or backups. |
| Destination safety | [Insertion code](../Sources/MouthtypeMac/Insertion/) rechecks captured app/field state, refuses secure destinations and retains text for recovery. [Tests](../Tests/MouthtypeMacTests/TextInserterTests.swift) cover denied and changed destinations. | Accessibility behavior differs across apps. Clipboard reads don't prove insertion, and a partial paste may need manual repair. |
| Editor hints | [Editor hints](SETTINGS.md) are off by default, run only in VS Code, Cursor, Xcode and supported terminals, and read the window title, the existing cursor-text window and git-tracked file names of one project. [Tests](../Tests/MouthtypeMacTests/EditorHintsTests.swift) cover the off state and that names stay out of stored history. | File names can be sensitive. They go only to the local recognizer, in memory for one dictation, and are never written or logged. A wrong tab or stale title can supply another project's names. |
| Names on screen | [Names on screen](SETTINGS.md) is on by default, but only acts when Boost saved words (off by default) is on. It reads up to 2000 characters of the focused text field and the window title, never a secure field or terminal, within the same 150 ms bound, and sets `AXManualAccessibility` once per Electron app. [Tests](../Tests/MouthtypeMacTests/ContextNamesGathererTests.swift) cover name extraction, secure-field exclusion, the deadline and the once-per-app flag. | Names from a message you were reading can be sensitive. They go only to the local recognizer, in memory for one dictation, and are never written or logged. The Electron flag makes that app build its Accessibility tree, which can cost it some CPU. |
| Imported audio | [File transcription](FILE-TRANSCRIPTION.md) accepts one bounded supported file, preserves the original and requires explicit Copy or Save. | Decoding and inference use platform and dependency code. Resource bounds aren't proof that every parser defect is prevented. |
| Mac distribution | [Release helpers](../scripts/package-release.py) require exact release identity, sign with Developer ID, notarize and verify the package. [Public staging](../scripts/stage-public-release.py) preserves versioned assets and creates the matching source archive and signed Sparkle feed. | Notarization isn't a security audit. Fresh-install and in-app upgrade acceptance must be verified separately for the release. [Release signing](#verify-a-download) adds a cosign signature and build provenance attestation to each asset. Releases are built in a [repeatable mode](REPEATABLE-BUILD.md) whose unsigned contents match across checkouts except `Assets.car`. Signed and notarized output isn't bit-for-bit reproducible. No SLSA level or SBOM claim is made. |
| Update delivery | [Updater](../Sources/MouthtypeMac/Updates/AppUpdater.swift) uses the configured HTTPS feed and Sparkle signing identity. Installation waits for active app work. | Network requests reveal ordinary request metadata to hosting providers. Release signing credentials remain a maintainer responsibility. |
| Dependencies | Swift and npm lockfiles preserve resolved inputs. [Dependabot](../.github/dependabot.yml) proposes weekly Swift, website and docs-site npm, and Actions updates to the active dev branch. Free repository vulnerability alerts are enabled. | Updates and alert availability don't prove complete Swift advisory coverage. |
| CI authority | External Actions are SHA pinned, checkout credentials aren't persisted, jobs have timeouts and explicit permissions. Security checks need read access only. | Hosted runner labels and package repositories still evolve. Downloaded tool versions and container digests need separate maintenance. |
| Swift CI | The [Swift workflow](../.github/workflows/swift.yml) runs on pull requests and on pushes to main and dev branches. The `build` job compiles with `-Xswiftc -warnings-as-errors`. The `test` job runs the Swift tests with code coverage, then `scripts/swift-coverage.sh` enforces an 80% line floor. Both `build` and `test` are required status checks on main and dev branches. | Hosted CI skips two suites and one parameterized test that need a free desktop (`SettingsKeyboardAccessTests`, `AppearancePreviewLiveTests` and `glassInAShownWindowOverEachSwatch`). The full suite runs locally once at each dev-to-main release merge. The 0.7.0 merge ran 2,741 tests with no skips. Line coverage doesn't show the tests assert the right things. |
| Secret and workflow checks | [Security CI](../.github/workflows/security.yml) runs full-history Gitleaks with redaction, actionlint, zizmor and the portable release-helper tests. The real `ditto` archive integration test runs on Mac and is explicitly skipped on Linux. Tool archives are SHA-256 verified before execution. `scripts/swift-fuzz.sh` runs libFuzzer with AddressSanitizer on the phrase matcher for 30 seconds. | Static checks have false negatives. The fuzz run covers the phrase matcher only. Zizmor runs offline, so audits requiring GitHub API metadata aren't included. |
| Website dependencies | Security CI uses `npm audit --package-lock-only --audit-level=high`, including development and transitive packages. The separate [website workflow](../.github/workflows/website.yml) builds and runs browser checks. | Advisory databases aren't complete; a clean audit isn't a guarantee. This check doesn't scan the `apps/docs` lockfile, Swift dependencies or downloaded model files. |

The maintainer reviews findings, dependency advisories, tool pins and shipped behavior. Don't send real transcripts or recordings to scanners or review tools as test fixtures.

## Verify a download

[release-sign.yml](../.github/workflows/release-sign.yml) signs every release asset with keyless cosign and attaches a `.sigstore.json` bundle next to each one. It also records a GitHub build provenance attestation. Download the asset and its bundle, then check both. This example uses the DMG, with `X.Y.Z` as the release version:

```sh
cosign verify-blob \
  --bundle Mouthtype-X.Y.Z-macos-arm64.dmg.sigstore.json \
  --certificate-identity-regexp '^https://github.com/CodesWhat/mouthtype/.github/workflows/release-sign.yml@refs/(heads/main|tags/v.+)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  Mouthtype-X.Y.Z-macos-arm64.dmg
gh attestation verify Mouthtype-X.Y.Z-macos-arm64.dmg --repo CodesWhat/mouthtype
```

Apple notarization and the Sparkle EdDSA signature on the update ZIP remain what macOS and the updater check when you install or update. The cosign signature and attestation let you check a download independently of those. Release builds use the [repeatable build](REPEATABLE-BUILD.md) mode, and each release manifest records it with the toolchain used. With the same source, toolchain and dependency versions, unsigned app contents match across checkouts except for `Contents/Resources/Assets.car`, which varies between builds. Signed and notarized output isn't bit-for-bit reproducible. The commands are also in [RELEASING.md](RELEASING.md#verifying-release-signatures).

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
5. **App to a listed website.** When a website appears in a Style list, [SiteFaviconStore](../Sources/MouthtypeMac/Settings/SiteFavicon.swift) fetches its icon once: `GET https://<site>/` to find the `<link rel="icon">` it names, then that icon, or `https://<site>/favicon.ico` as a fallback. Requests go only to the site itself (an icon link is followed only on the same site or a sibling subdomain), never to a third-party icon service. They use an ephemeral session with no cookies, a 5 second timeout, at most 5 https redirects, a 256 KB body cap and a plain `Mouthtype` User-Agent. The request reveals only the site name and the user's IP address to a site the user chose to list. Icons are cached under `~/Library/Caches/Mouthtype/SiteFavicons` for 30 days, and a failure is remembered for a day so a render never retries.
6. **Source to release.** Pull requests into the dev branch, Security CI, and the [release helpers](../scripts/package-release.py) that sign, notarize and verify.

### Secure design principles applied

- **Local first.** Transcription and the Fast and Thorough cleanup paths run on-device. The only network use in the app targets is model download, update checks and website icons in the Style lists. None carries audio or transcripts.
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
- Hosted CI skips two suites and one parameterized test that need a free desktop, so they run only locally at each dev-to-main release merge. No SBOM, SLSA level or independent third-party security review exists, and signed, notarized output isn't reproducible.
- Destination apps differ in how they handle Accessibility and paste, so a partial insertion can still need manual repair.
- Developer benchmark modes can send input to a Claude CLI and must use synthetic data.

These are tracked in the remaining work below.

## Remaining assurance work

- [x] Verify the first scheduled Dependabot processing and Scorecard report. Dependabot opened its first updates against the dev branch in October 2026 ([#464](https://github.com/CodesWhat/mouthtype/pull/464), [#468](https://github.com/CodesWhat/mouthtype/pull/468)), and Scorecard reports 8.2 for main at `d07aa34`.
- [ ] Triage the two open Scorecard findings: Maintained (the repository is younger than Scorecard's 90-day window) and Code-Review (dev-branch pull requests merge without a recorded approval; main requires two).
- [x] MLX cleanup models are pinned to exact Hugging Face commits in `CleanerCatalog`, so a changed upstream repo isn't picked up by a fresh download.
- [x] Speech models are pinned to exact Hugging Face commits in [ModelPins](../Sources/MouthtypeCore/ModelPins.swift), the single place to read or bump them. Parakeet v3 (`FluidInference/parakeet-tdt-0.6b-v3-coreml` at `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`), Parakeet v2 (`FluidInference/parakeet-tdt-0.6b-v2-coreml` at `ee09c569f73759e6d44c9bd16766f477b2b36d39`), the CTC-110M vocabulary model (`FluidInference/parakeet-ctc-110m-coreml` at `accdafd8cf8a2ff1cabe3c11e54416b405d409aa`), Silero VAD (`FluidInference/silero-vad-coreml` at `b419383c55c110e2c9271fa6ee0ea83d03c70d96`) and WhisperKit (`argmaxinc/whisperkit-coreml` at `0f63a7800b00dd0226abd051b906c246e1907482`). FluidAudio takes its pins through `ModelRegistry.revisionOverrides`. WhisperKit 1.1.1's `WhisperKit.download` has no revision parameter, so `WhisperModelFetch` runs the same variant lookup through `HubApiWrapper`, which does. Files are not hash-checked beyond what each library does. FluidAudio's fallback fetch of a missing Parakeet vocabulary JSON still resolves `main`, and a pin bump re-downloads the model once. Caches that predate the pins have no FluidAudio revision marker. FluidAudio adopts those itself when it can fetch the pinned file listing, so online they aren't re-downloaded. For a first launch with no network, `ModelCacheAdoption` checks the cache against a manifest bundled with the app (`ModelManifest.json`, generated at the pinned commits by `scripts/generate-model-manifest.py`) and writes the marker only if every required file is present and matches and no `.partial` file is left. Anything else is left for FluidAudio's own adoption or download.
- [ ] Establish automated Swift advisory coverage for the actual resolved packages and model supply chain. Until then, review upstream advisories and package changes before release; npm auditing doesn't cover them.
- [x] Swift builds with warnings as errors and runs tests with an 80% line coverage floor on a hosted macOS runner, as required checks. The desktop-dependent tests still run only locally at release merge.
- [x] Release assets carry a cosign signature and a GitHub build provenance attestation (see [Verify a download](#verify-a-download)).
- [ ] Add a dependency inventory/SBOM only with exact source and artifact identity, then verify it. None is published. No SLSA level is claimed.
- [ ] Get an independent third-party security review. None has happened.
- [ ] Keep physical installation, updates, permissions, microphone routing and destination-app acceptance in the release checks. Static scanner results don't replace them.

These are maintainer follow-ups, not claims that the repository has achieved a target Scorecard score or an OpenSSF Best Practices level above passing. See [SECURITY.md](../SECURITY.md) for supported releases and sensitive reporting.
