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

echo "→ building Mouthtype $VERSION (release, arm64)"
swift build -c release --arch arm64 --jobs 4 --product Mouthtype
swift build -c release --arch arm64 --jobs 4 --product mouthtype-fn-guard
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Mouthtype" "$APP/Contents/MacOS/Mouthtype"
strip -x "$APP/Contents/MacOS/Mouthtype"
cp "$BIN_DIR/mouthtype-fn-guard" "$APP/Contents/MacOS/mouthtype-fn-guard"
strip -x "$APP/Contents/MacOS/mouthtype-fn-guard"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp docs/ALPHA.md "$APP/Contents/Resources/Read Me.txt"
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
    BUNDLES+=("$APP/Contents/Resources/$(basename "$bundle")")
done

TIMESTAMP="--timestamp"
[ "${MOUTHTYPE_TIMESTAMP:-}" = "none" ] && TIMESTAMP="--timestamp=none"

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
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
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
