# Release source inventory

`scripts/generate-release-sbom.py` produces a CycloneDX 1.6 source inventory for a Mac release. It reads `Package.resolved` from that release's exact Git tag, records each resolved Swift package's version, repository and commit, and checks the ZIP and DMG against the release manifest's SHA-256 values before including their identities.

This is an incomplete source SBOM. Resolving a package does not establish which products or files were linked into the app. The inventory does not claim a dependency graph or build provenance. Downloaded speech and cleanup models, macOS and SDK libraries, website and docs packages, and experimental Linux dependencies are outside its scope. Model pins remain in [ModelPins.swift](../Sources/MouthtypeCore/ModelPins.swift); dependency notices remain in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Generate and check

Run from a reviewed checkout containing the release tag and helper. The helper reads source from the tag even when the checkout is newer. For release `X.Y.Z`, with the checked artifacts and manifest in `build/releases/X.Y.Z/X.Y.Z/`, run:

```sh
python3 scripts/generate-release-sbom.py --manifest build/releases/X.Y.Z/X.Y.Z/release-manifest.json --assets-dir build/releases/X.Y.Z/X.Y.Z --output build/releases/X.Y.Z/X.Y.Z/Mouthtype-X.Y.Z-sbom.cdx.json
```

It stops if the tag, source revision, version, artifact names or checksums disagree, or if a package lacks an exact source revision. It does not rebuild, sign or upload anything. Identical inputs produce identical JSON, without checkout or temporary-directory paths.

Before publishing, validate against the [official CycloneDX 1.6 JSON schema](https://github.com/CycloneDX/specification/blob/1.6/schema/bom-1.6.schema.json), compare every library with the tag's lockfile, and compare both file hashes with the downloaded release artifacts. Attach the JSON as an additional GitHub release asset, then dispatch `release-sign.yml` from main for that tag. Download the resulting inventory and its cosign bundle and verify them as described in [Verify a download](SECURITY.md#verify-a-download). Preserve the existing app, source, feed and signatures.

No inventory was published before this helper was added. An inventory signature proves who signed its bytes, not that its component list is complete or that CI built the app.
