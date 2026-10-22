#!/usr/bin/env bash
# Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
# Builds the release binary and wraps it in a signed Mouthtype.app.
#   scripts/build-app.sh [version]        → build/Mouthtype.app
#
# Release metadata comes from packaging/Version.plist. An optional version argument
# overrides the display/marketing version for a local build; the build number stays
# in Version.plist. Prerelease labels are kept out of Apple's numeric version fields.
#
# The mouthtype-fn-guard helper sits next to the app binary in Contents/MacOS. The app spawns it while the Fn
# remap is applied; it clears the remap if the app dies without restoring it.
#
# SwiftPM resource bundles (FluidAudio, GRDB, MLX's metallib, swift-crypto,
# swift-transformers) go in Contents/Resources: that is the first place their
# generated accessors look (Bundle.main.resourceURL), and MLX finds its
# metallib through NSBundle.allBundles, which includes the main bundle's
# resource directory. They are signed first, then the app.
#
# Signs with the first "Developer ID Application" identity in the keychain,
# with the hardened runtime and packaging/Mouthtype.entitlements. The
# designated requirement then names the bundle ID and the team, not a
# cdhash, so macOS keeps privacy grants across builds. Without an identity
# the app is ad-hoc signed and every build is a new identity; the script says so.
#
#   MOUTHTYPE_SIGN_IDENTITY   signing identity (default: the keychain's Developer ID)
#   MOUTHTYPE_TIMESTAMP=none  skip the secure timestamp (local builds, offline)
#   MOUTHTYPE_BUILD_DIR       output directory (default: build)
#   MOUTHTYPE_SCRATCH_PATH    repeatable-build mode. Copies the sources into <path>/mouthtype and builds
#                             them there with SwiftPM state in <path>/build, so every absolute path the
#                             compilers see is the same on any machine and in any checkout directory.
#                             Swift bakes source-path lengths into the binary, which no prefix-map flag
#                             fixes. Unset (the default) builds in place with .build, which is faster
#                             and keeps .build/artifacts populated but is not path-independent.
#   MOUTHTYPE_UNSIGNED=1      assemble the app but skip every codesign step (used by
#                             scripts/verify-repeatable-build.sh; never ship this output)
#
# The build maps the checkout path to /src in compiler output and pins the root package's
# resource-bundle identifier, so the unsigned contents do not depend on the checkout's
# directory name. See docs/REPEATABLE-BUILD.md.

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :MouthtypeDisplayVersion' packaging/Version.plist)}"
VERSION="${VERSION#v}"
SHORT_VERSION="${VERSION%%-*}"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' packaging/Version.plist)"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[1-9][0-9]*)?$ ]] || [[ ! "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid release version or build number" >&2
    exit 1
fi
OUT="${MOUTHTYPE_BUILD_DIR:-build}"
APP="$OUT/Mouthtype.app"

IDENTITY="${MOUTHTYPE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"

if [ -n "${MOUTHTYPE_SCRATCH_PATH:-}" ]; then
    mkdir -p "$MOUTHTYPE_SCRATCH_PATH"
    SRC="$(cd "$MOUTHTYPE_SCRATCH_PATH" && pwd -P)/mouthtype"
    SCRATCH="$(dirname "$SRC")/build"
    # ld's default (fast) objc stubs come out in one of two layouts at random from identical inputs;
    # the small stubs layout is deterministic.
    LINK_FLAGS=(-Xlinker -objc_stubs_small)
    echo "→ copying sources to $SRC"
    mkdir -p "$SRC"
    rsync -a --delete --exclude /.build --exclude /.git --exclude /build --exclude /.claude --exclude /.planning ./ "$SRC/"
else
    SRC="$PWD"
    SCRATCH="$PWD/.build"
    LINK_FLAGS=()
fi
SWIFT_ARGS=(-c release --arch arm64 --package-path "$SRC" --scratch-path "$SCRATCH")
# Keep the source path out of the binaries (C++ __FILE__ in Cmlx, Swift debug paths). The compilers
# see the resolved path (/private/var/... for a /var/... checkout), so map both spellings.
PATH_MAP_FLAGS=()
for root in "$SRC" "$(cd "$SRC" && pwd -P)"; do
    PATH_MAP_FLAGS+=(-Xcc "-ffile-prefix-map=$root=/src" -Xswiftc -file-prefix-map -Xswiftc "$root=/src")
    [ "$SRC" = "$(cd "$SRC" && pwd -P)" ] && break
done

echo "→ building Mouthtype $VERSION (release, arm64)"
# Run from $SRC: the tools' working directory still reaches the output (objc stub layout) otherwise.
(cd "$SRC" && swift build "${SWIFT_ARGS[@]}" --jobs 4 "${PATH_MAP_FLAGS[@]}" ${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"} --product Mouthtype)
(cd "$SRC" && swift build "${SWIFT_ARGS[@]}" --jobs 4 "${PATH_MAP_FLAGS[@]}" ${LINK_FLAGS[@]+"${LINK_FLAGS[@]}"} --product mouthtype-fn-guard)
BIN_DIR="$(cd "$SRC" && swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Mouthtype" "$APP/Contents/MacOS/Mouthtype"
strip -x "$APP/Contents/MacOS/Mouthtype"
cp "$BIN_DIR/mouthtype-fn-guard" "$APP/Contents/MacOS/mouthtype-fn-guard"
strip -x "$APP/Contents/MacOS/mouthtype-fn-guard"
# ld derives LC_UUID from its inputs' paths, so identical code gets a different UUID per checkout.
# Replace it with a hash of the binary's own contents. Done on copies outside the bundle (codesign
# on the main executable would sign the whole bundle early); the signing steps below add the
# signature back.
UUID_TMP="$(mktemp -d)"
for exe in Mouthtype mouthtype-fn-guard; do
    cp "$APP/Contents/MacOS/$exe" "$UUID_TMP/$exe"
    codesign --remove-signature "$UUID_TMP/$exe" 2>/dev/null || true
    python3 -I scripts/normalize-macho-uuid.py "$UUID_TMP/$exe"
    cp "$UUID_TMP/$exe" "$APP/Contents/MacOS/$exe"
done
rm -rf "$UUID_TMP"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# macOS 26 icon: the Icon Composer bundle compiled to Assets.car (CFBundleIconName), so the system masks it and
# renders Dark, Clear and Tinted. The .icns above stays as the fallback and is what CFBundleIconFile names;
# actool's own AppIcon.icns output is discarded. Needs Xcode's actool; without it the .icns alone ships.
if xcrun --find actool >/dev/null 2>&1; then
    ICON_OUT="$(mktemp -d)"
    trap 'rm -rf "$ICON_OUT"' EXIT
    xcrun actool "$PWD/design/icon/AppIcon.icon" --compile "$ICON_OUT" \
        --output-format human-readable-text --notices --warnings --errors \
        --output-partial-info-plist "$ICON_OUT/icon-info.plist" \
        --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
        --development-region en --target-device mac --minimum-deployment-target 26.0 --platform macosx
    cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
    test -s "$APP/Contents/Resources/Assets.car" || { echo "actool produced no Assets.car" >&2; exit 1; }
    rm -rf "$ICON_OUT"
    trap - EXIT
else
    echo "! actool not found; shipping the .icns icon only (no Dark, Clear or Tinted appearances)."
fi
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp docs/READ-ME.md "$APP/Contents/Resources/Read Me.txt"
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP/Contents/Info.plist"
plutil -insert MouthtypeDisplayVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -insert MouthtypeSourceRevision -string "$(git rev-parse HEAD)" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The bench target's fixtures bundle shares the products directory but isn't the app's.
BUNDLES=()
for bundle in "$BIN_DIR"/*.bundle; do
    case "$(basename "$bundle")" in *mouthtype-bench*) continue ;; esac
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
    # SwiftPM names the root package's bundle id after the checkout directory. Pin it to what a
    # checkout named "mouthtype" produces so the shipped id never depends on where the build ran.
    case "$(basename "$bundle")" in
        Mouthtype_*.bundle)
            target="$(basename "$bundle" .bundle)"
            plutil -replace CFBundleIdentifier -string "mouthtype.${target#Mouthtype_}.resources" \
                "$APP/Contents/Resources/$(basename "$bundle")/Contents/Info.plist"
            ;;
    esac
    BUNDLES+=("$APP/Contents/Resources/$(basename "$bundle")")
done

TIMESTAMP="--timestamp"
[ "${MOUTHTYPE_TIMESTAMP:-}" = "none" ] && TIMESTAMP="--timestamp=none"

if [ "${MOUTHTYPE_UNSIGNED:-}" = "1" ]; then
    echo "! MOUTHTYPE_UNSIGNED=1: assembling without code signatures."
    SPARKLE="$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    test -d "$SPARKLE"
    mkdir -p "$APP/Contents/Frameworks"
    ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
    echo "$APP"
    exit 0
fi

if [ -n "$IDENTITY" ]; then
    echo "→ signing as $IDENTITY"
    SIGN_AS="$IDENTITY"
else
    echo "! no Developer ID Application identity; ad-hoc signing."
    echo "  Permissions will not survive the next build, and the app can't be notarized."
    SIGN_AS="-"
    TIMESTAMP="--timestamp=none"
fi

# SwiftPM links this dynamic framework but does not assemble a standalone app.
SPARKLE="$SCRATCH/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
test -d "$SPARKLE"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
for nested in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app"; do
    codesign --force --options runtime $TIMESTAMP --preserve-metadata=entitlements --sign "$SIGN_AS" "$nested"
done
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_AS" "$FRAMEWORK"

# Inside-out: each nested bundle before the one that contains it.
for nested in "${BUNDLES[@]}"; do
    codesign --force --options runtime $TIMESTAMP --sign "$SIGN_AS" "$nested"
done
# The Fn guard helper is nested code in Contents/MacOS: signed before the app, with no entitlements.
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_AS" "$APP/Contents/MacOS/mouthtype-fn-guard"
codesign --force --options runtime $TIMESTAMP \
    --entitlements packaging/Mouthtype.entitlements \
    --sign "$SIGN_AS" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
echo "  designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "$APP"
