#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Use Apple's SDK-matched Swift. No full Xcode installation is required.
# CONFIGURATION=debug|release (default: debug), UNIVERSAL=1 for Intel + Apple Silicon.
# VERSION and BUILD_NUMBER override bundle metadata for release builds.
configuration="${CONFIGURATION:-debug}"
app="$PWD/.build/PomodoroBlocker.app"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    printf 'CONFIGURATION must be debug or release.\n' >&2
    exit 1
fi
version="${VERSION:-}"
if [[ -n "$version" && ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'VERSION must be a release version such as 1.2.3.\n' >&2
    exit 1
fi
if [[ -n "${BUILD_NUMBER:-}" && ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    printf 'BUILD_NUMBER must be a positive integer.\n' >&2
    exit 1
fi
mkdir -p .build
staging="$(mktemp -d "$PWD/.build/app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/PomodoroBlocker.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
executable="$bundle/Contents/MacOS/PomodoroBlocker"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    binaries=()
    for arch in arm64 x86_64; do
        triple="$arch-apple-macosx14.0"
        scratch="$PWD/.build/universal-$arch"
        xcrun swift build -c "$configuration" --triple "$triple" --scratch-path "$scratch"
        binaries+=("$(xcrun swift build -c "$configuration" --triple "$triple" --scratch-path "$scratch" --show-bin-path)/PomodoroBlocker")
    done
    xcrun lipo -create "${binaries[@]}" -output "$executable"
    xcrun lipo "$executable" -verify_arch arm64 x86_64
else
    xcrun swift build -c "$configuration"
    cp "$(xcrun swift build -c "$configuration" --show-bin-path)/PomodoroBlocker" "$executable"
fi
cp Resources/Info.plist "$bundle/Contents/Info.plist"
if [[ -n "$version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$bundle/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$bundle/Contents/Info.plist"
fi
# Sounds go in the bundle's Contents/Resources, where NSSound(named:) looks. SwiftPM's own resource
# bundles aren't used because Bundle.module can't find them inside a hand-assembled .app.
cp Resources/*.caf "$bundle/Contents/Resources/"
identity="${SIGNING_IDENTITY:--}"
if [[ "$identity" == - ]]; then
    codesign --force --sign - "$bundle"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$bundle"
fi
codesign --verify --strict "$bundle"
rm -rf "$app"
mv "$bundle" "$app"
printf 'Built %s\n' "$app"
