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
- Website build labels and redirects (`/download/file` to the new `.dmg`), and their existing browser checks

`SECURITY.md` must name the supported prerelease and retire the previous line. Keep publication on hold until the app, source, feed and website all select that exact version/build.

### 2. Tag the reviewed revision

Follow the CodesWhat dev-branch, reviewed-PR and main-sync procedure. Keep deferred work out of the candidate, preserve dirty checkouts, and tag only the reviewed main revision. Sign the annotated `v<display version>` tag with the existing GitHub-recognized release signing key and push it. The release helper refuses a dirty source tree or a HEAD that does not match that tag.

### 3. Package the release

Run `python3 scripts/package-release.py --output-dir /absolute/path/to/release-output` from the exact tagged source. It builds in repeatable mode (fixed scratch path `/private/tmp/mouthtype-release-scratch`, see [REPEATABLE-BUILD.md](REPEATABLE-BUILD.md)), signs, submits to Apple, waits with a ten-minute limit, staples, makes the final ZIP, extracts it, and requires signature/staple/Gatekeeper checks to pass on the extracted app. It then builds the DMG from the stapled app, signs it with the same Developer ID, notarizes and staples the DMG through the same submit/wait/log flow, mounts it read-only, and requires the signature, ticket and Gatekeeper (`spctl --type open`) checks to pass on the image and the app inside it.

The DMG is the public first-install download and the ZIP is the Sparkle update archive; the appcast keeps pointing at the ZIP. `scripts/build-dmg.py` makes the DMG: dmgbuild (pinned in `scripts/dmg/requirements.txt`, installed into the git-ignored `build/dmg-venv` on first run) writes the window layout and runs hdiutil, so no Finder scripting is involved. The window background comes from `scripts/dmg/background.py` (stdlib, deterministic, 1x and 2x combined with `tiffutil`) and the volume icon is rendered from the built app's own system icon by `scripts/dmg/volume-icon.swift`, so it keeps the squircle. The volume is named Mouthtype and compressed UDZO. Preview one without the release flow: `MOUTHTYPE_TIMESTAMP=none python3 scripts/build-dmg.py --app build/Mouthtype.app --output build/dmg-preview/Mouthtype.dmg`.

The ZIP contains only Mouthtype.app at its root so Finder expansion and Sparkle installation share the same artifact. Install notes and license are inside Contents/Resources. The helper never installs or launches the app and refuses to replace an existing release-output directory.

The manifest records `repeatableBuild`, `scratchPath` and the `toolchain` versions (`swift --version`, `xcodebuild -version`). To reproduce a release from its tag, follow "Releases are built this way" in REPEATABLE-BUILD.md.

Notarization uses the App Store Connect API key by default. The helper reads `ASC_KEY_ID` and `ASC_ISSUER_ID` from `~/.appstoreconnect/config.env`, finds the key at `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8`, and passes them to `notarytool` as `--key`, `--key-id` and `--issuer`. It never prints them. Pass `--notary-profile <name>` to use a Keychain profile instead. With neither available it stops before building. Never commit private keys, key IDs, issuer IDs or passwords.

> [!NOTE]
> If Apple rejects a submission, inspect the saved notarization result and log rather than forcing acceptance. If the bounded wait expires, the submission continues at Apple; inspect its saved submission ID before attempting another upload.

`--output-dir` is the parent: the helper writes the artifacts into `<output-dir>/<version>/`, so every later step points at that nested directory.

Attach the final DMG, ZIP, their SHA-256 files and release manifest to the GitHub release for provenance. The website provides the public downloads. Read the uploaded release back and compare a downloaded artifact’s checksum. Keep first-install, third-party-app and recognition limitations visible in release notes; do not describe unperformed checks as passed.

Generate and validate the [release source inventory](RELEASE-INVENTORY.md) against the same tag and checked artifacts. Attach it as an additional release asset and include it in the signing and download verification step. Its scope is the resolved Swift sources and verified artifact identities, not complete binary composition.

### 4. Stage the public release

After the tagged release is packaged and checked, run `scripts/stage-public-release.py` with the release directory and `--public-dir` pointing at a retained artifact directory outside disposable worktrees, such as the root checkout’s `build/public-release-assets`. It requires the DMG and checks the exact tag/source, archive and DMG digests, DMG notarization evidence, extracted signature/staple/Gatekeeper result and matching public key. It generates a corresponding source tarball and uses the pinned Sparkle tools to generate and verify the signed appcast.

The ZIP enclosure is EdDSA signed; the DMG is not part of the feed. The feed must remain byte-for-byte signed; re-sign after any change. New source archives contain committed source only, never local planning, credentials, recordings or worktrees.

Keep `build/public-release-assets` across releases. Staging preserves older versioned downloads, refuses changes to an existing versioned file and replaces only the current signed feed. Back up published release outputs; the retained directory is deployment state, not disposable compiler scratch. The website’s `/download/file` redirect must point at the release’s `.dmg` (not the ZIP), and `/source` at its source tarball, for the same release and build as the signed appcast. `publish-website.py` rejects a release whose manifest has a DMG when `/download/file` targets anything else, and validates every retained DMG’s checksum and notarization record.

`stage-public-release.py` also requires HEAD checked out at the exact release tag, because it runs the same source check as packaging.

### 5. Publish the website

Publish with `scripts/publish-website.py --public-dir` pointing at those retained artifacts. Without `--production` this validates only. The publisher requires every retained ZIP, DMG and source archive to exist in its published GitHub release, with matching SHA-256, size and public URL. Upload missing release assets before publishing; never overwrite a mismatched asset.

With `--production`, it exports committed `website/` files, small release manifests/checksums and the byte-identical signed feed. Exact versioned download URLs redirect to the verified GitHub assets. Large downloads are excluded from the Vercel deployment, so website deployment history does not duplicate the release archive. Local retained artifacts still provide the verification baseline. The publisher never uploads the app repository, local plans or signing credentials.

`--website-ref` can pin an already-reviewed website revision when changing delivery for the currently published app while a newer native candidate is pending. Its download/source routes must match the newest build in the retained signed feed. Deployment metadata records both the website revision and publisher revision; the default exports this checkout's `HEAD`.

> [!WARNING]
> Do not replace this with a bare site deployment that omits older release routes or changes the signed feed. Verify the complete redirected bodies anonymously after publication, not just GitHub's asset metadata.

Vercel preview/deployment authentication remains enabled; the public custom domain serves the download. Versioned release URLs are immutable, while `/download`, `/source` and the feed must not be cached as immutable.

The GitHub release is created before the source tarball exists. After uploading the tarball, dispatch `release-sign.yml` from main with the tag so the tarball gets its cosign bundle too.

### 5b. Publish the docs site

docs.mouthtype.app is a separate Vercel project, `mouthtype-docs`, with root `apps/docs`. Nothing deploys it automatically, so publish it by hand for each release. From the repository root on the release tree, run `vercel link --yes --scope codeswhat --project mouthtype-docs`, then `vercel build --prod --yes`, then `vercel deploy --prebuilt --prod --yes --scope codeswhat`. Afterward remove the root `.vercel/` directory and revert any `.gitignore` line the CLI added. Check that `reference/known-limits/` on the deployed site names the new version.

### 6. Verify after publishing

Verify each of these:

- The `/download` landing page’s five-second request and manual fallback.
- The actual custom-domain file/source redirects and complete DMG/source bodies, fetched without GitHub authentication, with their digests compared.
- The downloaded DMG’s signature/staple/Gatekeeper result, and the app inside it after mounting.
- The hosted feed signature.
- The visible website.

> [!NOTE]
> A unit test, HTTP 200, signed feed or updater-state test does not prove installation over an older live app. Coordinate an actual update-install/relaunch test separately; never use Scott’s running app for an uncoordinated update. Existing alpha.1–3 users must manually install the first updater-enabled build once.

## Verifying release signatures

`.github/workflows/release-sign.yml` runs when a release is published (or by manual dispatch with a tag). It signs every release asset with keyless cosign, attaches a `<asset>.sigstore.json` bundle next to each one, and records a build provenance attestation. It never re-uploads the original assets, so Sparkle signatures and notarization are untouched. A release event runs the workflow file from the tagged commit, so the signing identity is the tag ref for published releases and `main` for a dispatched backfill.

```sh
cosign verify-blob \
  --bundle Mouthtype-X.Y.Z-macos-arm64.dmg.sigstore.json \
  --certificate-identity-regexp '^https://github.com/CodesWhat/mouthtype/.github/workflows/release-sign.yml@refs/(heads/main|tags/v.+)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  Mouthtype-X.Y.Z-macos-arm64.dmg
gh attestation verify Mouthtype-X.Y.Z-macos-arm64.dmg --repo CodesWhat/mouthtype
```

To backfill an older release, dispatch `release-sign.yml` from `main` with its tag. Dispatch only works once the file is on `main`.

## Signing and Sparkle

Sparkle is pinned in `Package.swift` and `Package.resolved`. The app carries its framework, nested signed helpers and `@executable_path/../Frameworks` runpath. `scripts/build-app.sh` signs helpers inside out with the same Developer ID as the app. The feed URL and public key live in `packaging/Info.plist`. The dedicated Sparkle signing key stays in Keychain under account `com.codeswhat.mouthtype`. Back up that Keychain through the owner’s normal secure backup process.

> [!WARNING]
> Do not use `codesign --deep` to replace the inside-out signing order. Never export the Sparkle signing key into source, deployment files or logs.
