# Mac prereleases

How a Mac prerelease goes from version bump to a verified public download. Run the steps in order. Signing and Sparkle rules are at the end.

## Procedure

### 1. Bump version and metadata

Release metadata lives in `packaging/Version.plist`. The display version includes the prerelease label; Apple’s marketing version and positive integer build number remain numeric. Increment the build number for each distributed build.

Update these together:

- `packaging/ReleaseNotes.txt`
- `README.md`
- `SECURITY.md`
- `docs/READ-ME.md`
- Affected usage guides
- Website build labels and redirects, and their existing browser checks

`SECURITY.md` must name the supported prerelease and retire the previous line. Keep publication on hold until the app, source, feed and website all select that exact version/build.

### 2. Tag the reviewed revision

Follow the CodesWhat dev-branch, reviewed-PR and main-sync procedure. Keep deferred work out of the candidate, preserve dirty checkouts, and tag only the reviewed main revision. Sign the annotated `v<display version>` tag with the existing GitHub-recognized release signing key and push it. The release helper refuses a dirty source tree or a HEAD that does not match that tag.

### 3. Package the release

Run `python3 scripts/package-release.py --notary-profile mouthtype-notary --output-dir /absolute/path/to/release-output` from the exact tagged source. It builds, signs, submits to Apple, waits with a ten-minute limit, staples, makes the final ZIP, extracts it, and requires signature/staple/Gatekeeper checks to pass on the extracted app.

The ZIP contains only Mouthtype.app at its root so Finder expansion and Sparkle installation share the same artifact. Install notes and license are inside Contents/Resources. The helper never installs or launches the app and refuses to replace an existing release-output directory.

The notarization profile must already be stored in Keychain. Never commit private keys or passwords.

> [!NOTE]
> If Apple rejects a submission, inspect the saved notarization result and log rather than forcing acceptance. If the bounded wait expires, the submission continues at Apple; inspect its saved submission ID before attempting another upload.

Attach the final ZIP, SHA-256 file and release manifest to the GitHub release for provenance. The website provides the public downloads. Read the uploaded release back and compare a downloaded artifact’s checksum. Keep first-install, third-party-app and recognition limitations visible in release notes; do not describe unperformed checks as passed.

### 4. Stage the public release

After the tagged release is packaged and checked, run `scripts/stage-public-release.py` with the release directory and `--public-dir` pointing at a retained artifact directory outside disposable worktrees, such as the root checkout’s `build/public-release-assets`. It checks the exact tag/source, archive digest, extracted signature/staple/Gatekeeper result and matching public key. It generates a corresponding source tarball and uses the pinned Sparkle tools to generate and verify the signed appcast.

The ZIP enclosure is EdDSA signed. The feed must remain byte-for-byte signed; re-sign after any change. New source archives contain committed source only, never local planning, credentials, recordings or worktrees.

Keep `build/public-release-assets` across releases. Staging preserves older versioned downloads, refuses changes to an existing versioned file and replaces only the current signed feed. Back up published release outputs; the retained directory is deployment state, not disposable compiler scratch. The website’s `/download/file` and `/source` redirects must select the same release and build as the signed appcast.

### 5. Publish the website

Publish with `scripts/publish-website.py --public-dir` pointing at those retained artifacts. Without `--production` this validates only. With `--production` it exports only committed `website/` files plus the checked public artifacts and deploys them to the existing Mouthtype Vercel project. It never uploads the app repository, local plans or signing credentials.

> [!WARNING]
> Do not replace this with a bare site deployment that omits older release artifacts.

Vercel preview/deployment authentication remains enabled; the public custom domain serves the download. Versioned release URLs are immutable, while `/download`, `/source` and the feed must not be cached as immutable.

### 6. Verify after publishing

Verify each of these:

- The `/download` landing page’s five-second request and manual fallback.
- The actual custom-domain file/source redirects and complete ZIP/source bodies, fetched without GitHub authentication, with their digests compared.
- The downloaded app’s signature/staple/Gatekeeper result.
- The hosted feed signature.
- The visible website.

> [!NOTE]
> A unit test, HTTP 200, signed feed or updater-state test does not prove installation over an older live app. Coordinate an actual update-install/relaunch test separately; never use Scott’s running app for an uncoordinated update. Existing alpha.1–3 users must manually install the first updater-enabled build once.

## Signing and Sparkle

Sparkle is pinned in `Package.swift` and `Package.resolved`. The app carries its framework, nested signed helpers and `@executable_path/../Frameworks` runpath. `scripts/build-app.sh` signs helpers inside out with the same Developer ID as the app. The feed URL and public key live in `packaging/Info.plist`. The dedicated Sparkle signing key stays in Keychain under account `com.codeswhat.mouthtype`. Back up that Keychain through the owner’s normal secure backup process.

> [!WARNING]
> Do not use `codesign --deep` to replace the inside-out signing order. Never export the Sparkle signing key into source, deployment files or logs.
