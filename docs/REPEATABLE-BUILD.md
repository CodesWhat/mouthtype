# Repeatable build

With `MOUTHTYPE_SCRATCH_PATH` set, `scripts/build-app.sh` produces unsigned app contents that are byte-identical in any checkout directory, given the same toolchain (Xcode and Swift version) and the dependency versions in `Package.resolved`. Signed and notarized output is not bit-for-bit reproducible (see the exceptions below).

## Repeatable mode

```sh
MOUTHTYPE_SCRATCH_PATH=/private/tmp/mouthtype-release-scratch scripts/build-app.sh
```

The script copies the sources to `<path>/mouthtype`, keeps SwiftPM state in `<path>/build`, and builds from there. Unset, it builds in place with `.build`, which is faster and keeps `.build/artifacts` populated for the Sparkle tools, but it is not path-independent. These are the leaks it closes:

- Swift bakes the length of absolute source paths into the binary (`swift_isEscapingClosureAtFileLocation` calls), and no prefix-map flag changes that. A fixed source and scratch path does.
- Cmlx embeds absolute `__FILE__` paths. `-ffile-prefix-map` and `-file-prefix-map` map the source path to `/src`.
- SwiftPM names the root package's resource-bundle `CFBundleIdentifier` after the checkout directory. The script pins it to `mouthtype.MouthtypeMac.resources`, the value a checkout named `mouthtype` produces. The app bundle id `com.codeswhat.mouthtype` and everything notarization checks are untouched.
- ld derives `LC_UUID` from input paths. `scripts/normalize-macho-uuid.py` rewrites it to a hash of the binary's own contents.
- ld's default objc stubs come out in one of two layouts at random from identical inputs. `-Xlinker -objc_stubs_small` is deterministic.

## Verify it

```sh
scripts/verify-repeatable-build.sh        # add --keep to leave the temp checkouts and outputs
```

The script clones HEAD into two differently named temp directories, builds each unsigned (`MOUTHTYPE_UNSIGNED=1`, repeatable mode, no codesign, no notarization, no secrets), hashes every file in both apps and lists the differences. It builds committed content only, so commit first. Expect two full release builds, about eight minutes in total, including dependency fetches. It uses and then deletes `/private/tmp/mouthtype-repeatable-scratch`.

## Known exceptions

- `Contents/Resources/Assets.car`: `actool` produces a different file on every run from identical input, and there is no flag to fix it. The script reports it as an exception.
- Code signatures: Developer ID signatures embed a secure timestamp, so signed and notarized artifacts never match byte for byte. The verify script builds unsigned. A Mach-O whose only difference is its signature is also reported as an exception.
