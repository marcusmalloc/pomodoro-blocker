# Development

Builds require macOS 14+ and Swift 6 from Apple's Command Line Tools or Xcode.

```sh
scripts/run.sh       # Build and open a debug app.
scripts/install.sh   # Install a release app in ~/Applications.
```

The installer preserves durations and the block list. Set `APP_DIR` to choose another installation directory.

Full Xcode is needed for XCTest:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

Tests use isolated preferences and disable blocking. Use `PomodoroTimer(defaults:blockingEnabled:)` with a separate defaults suite and `blockingEnabled: false` for UI previews.

`MenuBarController.swift` owns the status item and commands; `AppPanels.swift` owns windows and focus. `TimerPanel.swift` lays out the clock, `ClockControl.swift` handles native input, and `PanelSurface.swift` shares styling. Countdown state and saved durations live in `PomodoroTimer.swift`.

After UI changes, check clicks, double-click editing, Return/Space, Escape, arrows, scrolling and Option reset. Switch phases while idle, paused and running. Closing during a pending click must leave the timer stopped. Check the block list, filtering, adding/removing items and reopening without flashes. Only installed apps should appear.

## Screenshots

```sh
scripts/screenshots.sh
```

This renders the production panels on a BareTab-style gradient and writes cursor-free PNGs to `docs/screenshots/`. It uses isolated preferences, disables blocking and includes sample apps only when installed. Pass an output directory to preview images without replacing the README assets.

## Releases

Push a stable version tag:

```sh
git tag v0.1.1
git push origin v0.1.1
```

GitHub Actions tests the app, builds a universal Intel/Apple Silicon archive, publishes its checksum, then updates [marcusmalloc/homebrew-tap](https://github.com/marcusmalloc/homebrew-tap). A dedicated SSH deploy key grants the release workflow write access only to that tap; its private key is stored in the app repository's `HOMEBREW_TAP_SSH_KEY` secret.

Rerun the release workflow with the same tag to retry publication. Published archives are preserved. The tap's manual **Update Pomodoro** workflow can also recover an interrupted cask update.

To package locally:

```sh
scripts/release.sh v0.1.1
```

Archives are written to `.build/releases/`. `SIGNING_IDENTITY` accepts a Developer ID identity; `NOTARY_PROFILE` accepts a configured `notarytool` keychain profile. Current automated releases are ad-hoc signed and retain macOS quarantine checks.

## Website blocking

Blocking uses `/etc/hosts`, including `www.` variants. Other subdomains need separate entries. Existing connections and proxies can bypass these entries. A helper requests administrator access once per launch and removes the block when focus ends, pauses or resets, or the app quits.

After a crash or power loss, stale entries may remain between `# BEGIN PomodoroBlocker` and `# END PomodoroBlocker`; the next focus session clears them, or they can be removed manually.
