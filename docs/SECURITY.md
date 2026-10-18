# Security controls and limits

Mouthtype is a single-user local dictation app, plus experimental Linux source and a static download website. Its meaningful boundaries are microphone capture, Accessibility-based text delivery, imported audio and local files, downloaded models, dependencies, and the signed release/update path. It isn't a hosted transcription service or a multi-tenant application.

## Implemented controls

| Area | Control and evidence | Limit |
| --- | --- | --- |
| Local data | [Audio retention](AUDIO-RETENTION.md) limits completed audio while preserving recoverable takes. Data is stored in the user's Application Support directory. | Text history is indefinite. Mouthtype doesn't encrypt its database, recordings or backups. |
| Destination safety | [Insertion code](../Sources/MouthtypeMac/Insertion/) rechecks captured app/field state, refuses secure destinations and retains text for recovery. [Tests](../Tests/MouthtypeMacTests/TextInserterTests.swift) cover denied and changed destinations. | Accessibility behavior differs across apps. Clipboard reads don't prove insertion, and a partial paste may need manual repair. |
| Imported audio | [File transcription](FILE-TRANSCRIPTION.md) accepts one bounded supported file, preserves the original and requires explicit Copy or Save. | Decoding and inference use platform and dependency code. Resource bounds aren't proof that every parser defect is prevented. |
| Mac distribution | [Release helpers](../scripts/package-release.py) require exact release identity, sign with Developer ID, notarize and verify the package. [Public staging](../scripts/stage-public-release.py) preserves versioned assets and creates the matching source archive and signed Sparkle feed. | Notarization isn't a security audit. Fresh-install and in-app upgrade acceptance must be verified separately for the release. No SLSA level or reproducible-build claim is made. |
| Update delivery | [Updater](../Sources/MouthtypeMac/Updates/AppUpdater.swift) uses the configured HTTPS feed and Sparkle signing identity. Installation waits for active app work. | Network requests reveal ordinary request metadata to hosting providers. Release signing credentials remain a maintainer responsibility. |
| Dependencies | Swift and npm lockfiles preserve resolved inputs. [Dependabot](../.github/dependabot.yml) proposes weekly Swift/npm/Actions updates to the active dev branch. Free repository vulnerability alerts are enabled. | Bot configuration needs to reach the default branch before scheduling. Updates and alert availability don't prove complete Swift advisory coverage. |
| CI authority | External Actions are SHA pinned, checkout credentials aren't persisted, jobs have timeouts and explicit permissions. Security checks need read access only. | Hosted runner labels and package repositories still evolve. Downloaded tool versions and container digests need separate maintenance. |
| Secret and workflow checks | [Security CI](../.github/workflows/security.yml) runs full-history Gitleaks with redaction, actionlint, zizmor and release-helper tests. Tool archives are SHA-256 verified before execution. | Static checks have false negatives. Zizmor runs offline, so audits requiring GitHub API metadata aren't included. |
| Website dependencies | Security CI uses `npm audit --package-lock-only --audit-level=high`, including development and transitive packages. The separate [website workflow](../.github/workflows/website.yml) builds and runs browser checks. | Advisory databases aren't complete; a clean audit isn't a guarantee. This check doesn't scan Swift dependencies or downloaded model files. |

The maintainer reviews findings, dependency advisories, tool pins and shipped behavior. Don't send real transcripts or recordings to scanners or review tools as test fixtures.

## OpenSSF readiness while private

The [private posture workflow](../.github/workflows/security-scorecard.yml) runs the official Scorecard CLI against the remote default branch and retains JSON as a private Actions artifact for seven days. It doesn't publish to OpenSSF, upload SARIF, request OIDC, add a public badge or change repository visibility. It reports observations; no aggregate-score threshold substitutes for reviewing individual results and errors.

The official [Scorecard Action documentation](https://github.com/ossf/scorecard-action#readme) directs private repositories without GitHub Advanced Security to use the CLI. The CLI report can still contain unavailable checks because of API permissions, platform support or private-repository behavior. A successful process exit or artifact upload doesn't make those checks pass. Workflow credentials have read access to the repository's code, checks, actions, issues and pull requests, without administrative permission.

As observed on October 17, 2026, GitHub returned HTTP 403 for both ruleset and classic branch-protection inspection on this private repository, with an upgrade/public-visibility requirement. No protection settings were weakened, billing changed or paid scanning enrolled. `CODEOWNERS` requests review but doesn't enforce approval by itself. Required-review enforcement and private CodeQL/SARIF availability remain unverified or unavailable under the current plan. The reviewed development-branch release procedure remains the operating rule.

## Remaining assurance work

- Verify the first scheduled Dependabot processing and private posture report after the configuration reaches the default branch. Triage each error or finding, especially review, CI and protection detection.
- Establish automated Swift advisory coverage for the actual resolved packages and model supply chain. Until then, review upstream advisories and package changes before release; npm auditing doesn't cover them.
- Add a native Mac CI lane that actually compiles and runs meaningful Swift tests on the supported Apple Silicon/macOS toolchain. Existing Linux gesture tests and local Mac acceptance don't establish hosted Mac CI coverage.
- Add dependency inventory/SBOM and build provenance only with exact source and artifact identity, then verify them. These aren't currently published guarantees.
- Keep physical installation, updates, permissions, microphone routing and destination-app acceptance in the release checks. Static scanner results don't replace them.

These are maintainer follow-ups, not claims that the repository has achieved a target Scorecard score or OpenSSF Best Practices certification. See [SECURITY.md](../SECURITY.md) for supported releases and sensitive reporting.
