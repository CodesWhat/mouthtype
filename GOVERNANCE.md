# Mouthtype Governance

## Model

Mouthtype uses a lead-maintainer model. Work is proposed and reviewed in public issues, discussions and pull requests. The lead maintainer owns project scope, release readiness and the final call when consensus can't be reached.

| Role | Current assignment | Responsibilities |
| --- | --- | --- |
| Lead maintainer | [`@scttbnsn`](https://github.com/scttbnsn) | Product direction, issue triage, security response, review and merge, and final technical decisions |
| Release owner | [`@scttbnsn`](https://github.com/scttbnsn) | Version bump, tagging, packaging, Developer ID signing, notarization, Sparkle signing and publishing, following [docs/RELEASING.md](docs/RELEASING.md) |
| Continuity maintainer | [`@biggest-littlest`](https://github.com/biggest-littlest) | CodesWhat organization administration, access recovery and release continuity when the lead maintainer is unavailable |
| Reviewers | Accounts in [`.github/CODEOWNERS`](.github/CODEOWNERS) (`@scttbnsn`, `@dstahl11`) | Review changes in owned areas and flag risk, compatibility and test gaps. `@dstahl11` owns the experimental Linux client under `tools/` |
| Contributors | Anyone using issues, discussions or pull requests | Propose, implement, test, document and review changes |

Roles come from sustained project work and trust. The lead maintainer adds or removes reviewers and maintainers through a public pull request that updates the relevant records. Organization-owner changes show up in GitHub's organization audit log.

## Decisions and disputes

Routine changes are decided in pull-request review. Larger changes should start with an issue or discussion that lays out the problem, the alternatives, the security and compatibility effects, and the outcome you want. We look for rough consensus. When a timely decision is needed and there isn't one, the lead maintainer decides and records the reason in the issue or pull request.

If you disagree with a decision, say so in that thread with the new information or evidence. If it's still unresolved, the continuity maintainer can be asked to take a second look, and the lead maintainer makes the final call after that. Disputes about conduct go through [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Security reports follow [`SECURITY.md`](SECURITY.md) and stay private until a fix is ready.

## Change and release control

Changes are made on branches and merged through pull requests into the active `dev/vX.Y.Z` branch. `main` advances through a reviewed development-branch sync and is the source for release tags. Required CI checks must pass before merge, and nobody bypasses or weakens branch protection. The full release steps are in [docs/RELEASING.md](docs/RELEASING.md).

## Access continuity

The repository belongs to the CodesWhat GitHub organization, which has two owner accounts: `@scttbnsn` and `@biggest-littlest`. Either owner can administer the repository, restore maintainer access, manage Actions and secrets, merge approved work and keep the issue and pull-request process going. Canonical source, issues, CI and release assets live on GitHub, and the release assets are signed in CI with keyless cosign and attested through GitHub Actions OIDC, so that part doesn't depend on a key on anyone's workstation.

The macOS signing pipeline is the exception. Developer ID signing, notarization and Sparkle update signing run on the release owner's Mac. The Developer ID certificate, the App Store Connect API key used for notarization and the Sparkle EdDSA signing key are held there, not in GitHub, and `@biggest-littlest` doesn't hold copies. If `@scttbnsn` becomes unavailable, this is what the other owner can and can't do:

- Can: keep the project running, merge reviewed work, cut source releases from a tagged revision (unsigned, built from source by users, with the cosign signature and attestation from `release-sign.yml`), revoke stale access, and rotate or revoke GitHub and App Store Connect credentials.
- Can't: ship a new signed and notarized app or a Sparkle update that existing installs will accept. That needs the Developer ID identity and the Sparkle key, or replacements for them. A new Developer ID and a new App Store Connect key can be issued under the Apple Developer account. A new Sparkle key can't update existing installs, because they trust the public key in the shipped app, so those users would have to install a new build by hand once.

The Sparkle key backup is the release owner's responsibility, as noted in [docs/RELEASING.md](docs/RELEASING.md). Until a second maintainer holds a tested copy of the signing credentials, signed-release continuity is limited as described above. Forking is always available under GPL-3.0, but it isn't the primary continuity plan.
