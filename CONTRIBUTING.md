# Contributing

Mouthtype's repository is private. Access doesn't authorize publishing its working tree or private planning. Released GPL source is distributed separately from [mouthtype.app/source](https://mouthtype.app/source).

## Working branches

Branch from `dev/v0.1.0` and open a pull request back to that branch. Keep changes focused and preserve other agents' work. Don't switch a checkout with unrelated edits. `main` advances through a reviewed development-branch sync before a release. Don't bypass or weaken branch protection.

Use plain Conventional Commits: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore` or `revert`, optionally with a scope. Keep `.claude/` and `.planning/` ignored; no build or test may depend on ignored planning files.

## Checks

- Mac code: Xcode with Swift 6.2 on Apple Silicon and macOS 26 or later, then `swift test`. Add meaningful regression coverage for changed behavior. Physical microphone and destination-app checks are separate from logic tests.
- Release helpers: `python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'`.
- Website: `npm --prefix website ci`, `npm --prefix website run build`, then `npm --prefix website test`. Install the Playwright browser as described in [website/README.md](website/README.md).
- Linux: use the component and fixture commands in [tools/linux-desktop/README.md](tools/linux-desktop/README.md). Source checks don't establish physical desktop acceptance.
- Security: run `gitleaks git --redact --no-banner`, `actionlint`, and `zizmor --no-progress .github/workflows` when those tools are installed. Security CI also audits the website lockfile. Keep scanner findings and synthetic fixtures free of personal data.

Never launch desktop self-tests or replace a running app while another person or agent is using it. Read [the release procedure](docs/RELEASING.md) before signing, notarizing or publishing. Confirm actual downloaded artifacts and source identity before calling distribution verified.

## Dependency and security maintenance

Dependabot proposes weekly Swift, npm and GitHub Actions updates against the active development branch. Review changes and run the relevant checks; updates aren't merged automatically. The configuration takes effect after reaching the default branch. Dependency alerts are separate from version-update PRs.

The maintainer also reviews release-tool pins, container image digests and Swift upstream security advisories at least monthly and before releases. GitHub Actions update automation doesn't maintain shell-downloaded tool versions or container references in arbitrary workflow fields. Swift package version updates aren't a claim of complete advisory coverage.

[Security controls and limits](docs/SECURITY.md) records checks that remain unavailable or incomplete. Don't hide scanner execution failures behind successful uploads, broad allowlists or `continue-on-error`. Any exception needs a specific finding, an owner and a condition for rechecking it. Use [SECURITY.md](SECURITY.md) for sensitive reports.
