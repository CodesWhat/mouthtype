# Repeatable build

The unsigned contents of `Mouthtype.app` come out byte-identical no matter which directory the repo is checked out in, given the same toolchain (Xcode and Swift version) and the same dependency versions from `Package.resolved`.

## What makes it path-independent

- `scripts/build-app.sh` passes `-ffile-prefix-map` to clang and `-file-prefix-map` to swiftc, mapping the checkout path to `/src`. Without it Cmlx embeds absolute `__FILE__` paths from the checkout.
- SwiftPM names the root package's resource-bundle `CFBundleIdentifier` after the checkout directory (`<dirname>.MouthtypeMac.resources`). The script rewrites it to `mouthtype.MouthtypeMac.resources`, the value a checkout named `mouthtype` produces. The app bundle id `com.codeswhat.mouthtype` is untouched, and dependency bundles already use their package names.

## Verify it

```sh
scripts/verify-repeatable-build.sh        # add --keep to leave the temp checkouts and outputs
```

The script clones HEAD into two differently named temp directories, builds each with `MOUTHTYPE_UNSIGNED=1 scripts/build-app.sh` (no codesign, no notarization, no secrets), hashes every file in both apps and lists the differences. It builds committed content only, so commit first. Expect two full release builds, including dependency fetches.

## Known exceptions

- `Contents/Resources/Assets.car`: `actool` produces a different file on every run from identical input, and there is no flag to fix it. The script reports it as an exception.
- Code signatures: Developer ID signatures embed a secure timestamp, so signed and notarized artifacts never match byte for byte. The verify script builds unsigned. A Mach-O whose only difference is its linker ad-hoc signature is also reported as an exception.

A signed release is therefore not bit-for-bit reproducible. The claim covers the unsigned app contents, minus `Assets.car`.
