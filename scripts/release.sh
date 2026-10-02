#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:-}"
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf 'Usage: %s vMAJOR.MINOR.PATCH\n' "$0" >&2
    exit 1
fi
version="${tag#v}"
CONFIGURATION=release UNIVERSAL=1 VERSION="$version" BUILD_NUMBER="${BUILD_NUMBER:-1}" ./scripts/build.sh

app="$PWD/.build/PomodoroBlocker.app"
output="$PWD/.build/releases"
archive="PomodoroBlocker-$version-universal.zip"
mkdir -p "$output"

# A Developer ID identity can be supplied through SIGNING_IDENTITY. A local
# notarytool keychain profile is optional; ad-hoc builds retain Gatekeeper checks.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "${SIGNING_IDENTITY:--}" == - ]]; then
        printf 'Notarization requires SIGNING_IDENTITY to be a Developer ID identity.\n' >&2
        exit 1
    fi
    ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
    xcrun notarytool submit "$output/$archive" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
fi

# Package again after stapling so the downloaded app includes the ticket.
rm -f "$output/$archive"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$archive"
(
    cd "$output"
    shasum -a 256 "$archive" > "$archive.sha256"
    shasum -a 256 -c "$archive.sha256"
)
printf 'Release files: %s/%s{,.sha256}\n' "$output" "$archive"
