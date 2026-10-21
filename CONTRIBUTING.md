# Contributing

Thanks for wanting to help. Mouthtype is GPL-licensed. Released source is also available at [mouthtype.app/source](https://mouthtype.app/source).

Questions and ideas go in [Discussions](https://github.com/CodesWhat/mouthtype/discussions). Bugs go in [Issues](https://github.com/CodesWhat/mouthtype/issues). Report vulnerabilities through [SECURITY.md](SECURITY.md), not in either.

## How contributions work

Fork the repo, branch from the active development branch and open a pull request back to it. The active branch is the newest one listed by:

```sh
git branch -r --list 'origin/dev/v*'
```

Keep changes focused. `main` advances through a reviewed development-branch sync before a release. Don't bypass or weaken branch protection.

Use plain Conventional Commits: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore` or `revert`, optionally with a scope. Keep local scratch directories out of commits; no build or test may depend on ignored files.

## Checks

- Mac code: Xcode with Swift 6.2 on Apple Silicon and macOS 26 or later, then `swift test`. Add meaningful regression coverage for changed behavior. Physical microphone and destination-app checks are separate from logic tests. You don't need a Developer ID or notarization to contribute.
- Release helpers: `python3 -m unittest discover -s Tests/ReleaseTests -p 'test_*.py'`. The real archive integration test requires macOS `ditto`; Linux explicitly skips that one test.
- Website: `npm --prefix website ci`, `npm --prefix website run build`, then `npm --prefix website test`. Install the Playwright browser as described in [website/README.md](website/README.md).
- Linux: the experimental client under `tools/` has its own owner listed in [CODEOWNERS](.github/CODEOWNERS). Use the component and fixture commands in [tools/linux-desktop/README.md](tools/linux-desktop/README.md). Source checks don't establish physical desktop acceptance.
- Security: run `gitleaks git --redact --no-banner --gitleaks-ignore-path /dev/null`, `actionlint`, and `zizmor --no-progress .github/workflows` when those tools are installed. Security CI also audits the website lockfile. Keep scanner findings and synthetic fixtures free of personal data.

Optional benchmark cleaners and judge modes can invoke the Claude CLI and send their input to its service. Use synthetic text for those modes; they aren't the shipped Mac dictation path.

Desktop self-tests take focus, so don't run them while you're using the Mac. The release procedure in [docs/RELEASING.md](docs/RELEASING.md) is maintainer-only.

## Dependency and security maintenance

Dependabot proposes weekly Swift, npm and GitHub Actions updates against the active development branch. Review changes and run the relevant checks; updates aren't merged automatically. The configuration takes effect after reaching the default branch. Dependency alerts are separate from version-update PRs.

The maintainer also reviews release-tool pins, container image digests and Swift upstream security advisories at least monthly and before releases. GitHub Actions update automation doesn't maintain shell-downloaded tool versions or container references in arbitrary workflow fields. Swift package version updates aren't a claim of complete advisory coverage.

[Security controls and limits](docs/SECURITY.md) records checks that remain unavailable or incomplete. Don't hide scanner execution failures behind successful uploads, broad allowlists or `continue-on-error`. Any exception needs a specific finding, an owner and a condition for rechecking it.
