#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Render the real SwiftUI panels, without UI automation, a mouse pointer or personal preferences.
output="${1:-$PWD/docs/screenshots}"
mkdir -p "$output" .build
staging="$(mktemp -d "$PWD/.build/screenshots.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/PomodoroScreenshots.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.marcusmalloc.pomodoroblocker.screenshots</string>
<key>CFBundleExecutable</key><string>PomodoroScreenshots</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

sources=()
for source in Sources/PomodoroBlocker/*.swift; do
    [[ "$source" == */PomodoroBlockerApp.swift ]] || sources+=("$source")
done
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$PWD/.build/screenshot-module-cache" \
    "${sources[@]}" scripts/ScreenshotRenderer.swift \
    -o "$app/Contents/MacOS/PomodoroScreenshots"
"$app/Contents/MacOS/PomodoroScreenshots" "$output"
