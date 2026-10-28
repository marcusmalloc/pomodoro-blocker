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

Blocking uses `/etc/hosts`, including `www.` variants. Other subdomains need separate entries. Proxies can bypass these entries. The first focus session installs a root-owned `PomodoroDomainHelper` executable and a per-user launch daemon with one administrator prompt. The daemon stays installed across app launches, login and reboot; focus sessions do not request authorization again. If its background item is disabled, the app reports that instead of requesting another password.

Helper revisions are tracked in the root-owned launch daemon plist and fresh helper status. A known older helper is replaced with administrator approval once when its revision changes; subsequent sessions reuse it. A disabled helper or stale status does not trigger another authorization prompt. Protocol version 1 remains compatible with older app clients. Hosts directory resolution uses POSIX `realpath` so macOS's `/etc` and `/tmp` symlinks can be opened without weakening `O_NOFOLLOW` checks.

The app writes bounded, validated domain requests into a precreated `0600` file under a root-owned directory. Requests identify the process by UID, PID and kernel start time and have a ten-second lease renewed every two seconds. The daemon acknowledges applied changes, preserves unrelated hosts entries and file permissions, and clears its section on pause, break, quit, process death, lease expiry or daemon restart. Each user's section has separate `uid=` markers. Complete sections from the old temporary helper are migrated automatically.

Browsers reuse HTTP/2 and QUIC connections without a new DNS lookup, so hosts entries alone miss sites that were already open. While a block is active, the daemon also loads pf rules into `com.apple/000.PomodoroBlocker.<uid>`, an anchor under the `com.apple/*` hook macOS loads at boot. New web connections pass. TCP packets to ports 80 and 443 that pf has no state for are reset, and UDP to port 443 is blocked, so QUIC/HTTP3 is off during focus. Two seconds after a block starts or gains a domain, the daemon clears pf's state table. Every existing web connection resets once, and browsers reconnect through DNS into the hosts block. A VPN that tunnels over UDP port 443 loses its connection during focus. The pass rule isn't `quick`, so a later anchor's block, such as a VPN kill switch, still applies.

pf is reference-counted. The daemon takes one enable reference per block and keeps its token in a root-only `pf-token` file beside `status.json`. Ending the block or stopping the daemon flushes the anchor and releases the reference; a restarted daemon releases whatever a crashed one left. A pf failure leaves the hosts block in place and is reported in the app.

`DomainBlockingTests` covers request validation, stale process identities, marker migration, preservation of unrelated entries, the pf rules as `pfctl` parses them, enable tokens and when connections are reset. The helper also accepts `--test <uid> <hosts-copy> <prepared-directory>` only as an unprivileged process using its own UID. The prepared directory must be owned by that user with mode `0755`; this mode never touches system hosts, DNS caches or pf.

After building, verify the helper against disposable files (without `sudo`):

```sh
python3 scripts/test-domain-helper.py .build/PomodoroBlocker.app/Contents/Resources/PomodoroDomainHelper
```

To remove the installed background helper, quit the app and run:

```sh
sudo launchctl bootout "system/com.marcusmalloc.pomodoroblocker.domains.$(id -u)"
sudo rm "/Library/LaunchDaemons/com.marcusmalloc.pomodoroblocker.domains.$(id -u).plist"
```

Stopping the daemon removes its pf anchor and reference. If it couldn't stop cleanly, also run:

```sh
sudo pfctl -a "com.apple/000.PomodoroBlocker.$(id -u)" -F rules
sudo pfctl -X "$(sudo cat "/var/run/PomodoroBlocker-$(id -u)/pf-token")"
```

The executable is shared across users. After removing every PomodoroBlocker launch daemon, it can also be deleted from `/Library/PrivilegedHelperTools/com.marcusmalloc.pomodoroblocker.domains`. Runtime request files live under `/var/run/PomodoroBlocker-<uid>` and are cleared at reboot.
