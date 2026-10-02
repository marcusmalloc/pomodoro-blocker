#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# APP_DIR is the containing directory, not the .app path.
app_dir="${APP_DIR:-$HOME/Applications}"
destination="$app_dir/PomodoroBlocker.app"
bundle_id="com.marcusmalloc.pomodoroblocker"

check_identity() {
    local bundle="$1" identity
    if [[ -L "$bundle" || ! -d "$bundle" ]]; then
        printf 'Refusing to replace an unexpected app at %s\n' "$bundle" >&2
        exit 1
    fi
    identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identity" != "$bundle_id" ]]; then
        printf 'Expected %s at %s; found %s\n' "$bundle_id" "$bundle" "${identity:-no bundle identifier}" >&2
        exit 1
    fi
}

if [[ -e "$destination" || -L "$destination" ]]; then
    check_identity "$destination"
fi

CONFIGURATION="${CONFIGURATION:-release}" ./scripts/build.sh
source_app="$PWD/.build/PomodoroBlocker.app"
check_identity "$source_app"
test -x "$source_app/Contents/MacOS/PomodoroBlocker"
codesign --verify --strict "$source_app"

mkdir -p "$app_dir"
staging="$(mktemp -d "$app_dir/.PomodoroBlocker.install.XXXXXX")"
cleanup() {
    if [[ -d "$staging/previous.app" ]]; then
        printf 'Previous app preserved at %s\n' "$staging/previous.app" >&2
    else
        rm -rf "$staging"
    fi
}
trap cleanup EXIT
ditto "$source_app" "$staging/PomodoroBlocker.app"
codesign --verify --strict "$staging/PomodoroBlocker.app"

if pgrep -x PomodoroBlocker >/dev/null; then
    # SIGTERM also lets the domain helper observe that the app has exited.
    pkill -TERM -x PomodoroBlocker || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        if ! pgrep -x PomodoroBlocker >/dev/null; then
            break
        fi
        sleep 0.1
    done
    if pgrep -x PomodoroBlocker >/dev/null; then
        printf 'PomodoroBlocker is still running. Quit it, then run this installer again.\n' >&2
        exit 1
    fi
fi

# Recheck before moving an existing bundle and keep it until replacement succeeds.
if [[ -e "$destination" || -L "$destination" ]]; then
    check_identity "$destination"
    mv "$destination" "$staging/previous.app"
fi
if ! mv "$staging/PomodoroBlocker.app" "$destination"; then
    if [[ -d "$staging/previous.app" ]]; then
        mv "$staging/previous.app" "$destination"
    fi
    exit 1
fi
rm -rf "$staging/previous.app"

printf 'Installed %s\n' "$destination"
open "$destination"
