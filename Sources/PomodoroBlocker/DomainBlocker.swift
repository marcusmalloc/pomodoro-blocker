import Foundation
import Observation

/// Keeps chosen domains unreachable from every browser and app while a focus phase runs, by pointing them at
/// nowhere in /etc/hosts. Only root can edit that file, so the first focus phase after launch that has domains
/// to block asks for an administrator password and starts a small root helper that stays until this app quits.
/// The helper takes its orders from a file only this user can write. It removes the block when told to, when the
/// app quits and when it's asked to terminate, so normally nothing is left behind.
@MainActor
@Observable
final class DomainBlocker {
    /// Domains to block, as returned by `parse`. Changes made during a focus phase apply straight away if the
    /// helper is already running, and otherwise from the next phase, since asking for the password while
    /// someone is still typing the list would be a poor moment.
    var domains: [String] = [] {
        didSet {
            guard domains != oldValue else { return }
            if domains.isEmpty { problem = nil }
            send()
        }
    }

    /// On while a focus phase is running. The first time it comes on with domains to block, the helper is
    /// started, which is when the password is asked for.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive, !domains.isEmpty { startHelperIfNeeded() }
            send()
        }
    }

    /// Why domains aren't being blocked, or nil if they are or don't need to be.
    private(set) var problem: String?

    private enum Helper {
        case stopped
        /// Waiting for the password to be entered.
        case starting
        case running(pid: pid_t, requests: URL)
    }
    @ObservationIgnored private var helper = Helper.stopped

    /// Host names the helper is asked to block: each domain and its www. form. Other subdomains aren't covered
    /// because /etc/hosts has no wildcards, so they have to be listed.
    private var hostNames: [String] {
        domains.flatMap { [$0, "www.\($0)"] }
    }

    /// The domains in what was typed, one per line or separated by spaces or commas. Anything that names a host
    /// is accepted, so pasting an address works: "https://www.Reddit.com/r/swift" gives "reddit.com". Entries
    /// that aren't a valid host name, and repeats, are dropped.
    nonisolated static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split { $0.isWhitespace || $0 == "," || $0 == ";" }
            .compactMap { domain(in: String($0)) }
            .filter { seen.insert($0).inserted }
    }

    private nonisolated static func domain(in entry: String) -> String? {
        // URL does the work of finding the host in an address and turns non-ASCII names into punycode.
        guard var host = URL(string: entry.contains("://") ? entry : "https://\(entry)")?.host()?.lowercased() else {
            return nil
        }
        // "*.example.com" and "example.com." mean the same as "example.com" here.
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if host.hasSuffix(".") { host.removeLast() }
        // Both forms get blocked anyway, so "www." only gets in the way.
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        return isHostName(host) ? host : nil
    }

    /// Letters, digits and hyphens in at least two dot-separated labels, the last starting with a letter. The
    /// helper checks the same again before touching /etc/hosts.
    private nonisolated static func isHostName(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2, labels.last!.count >= 2, labels.last!.first!.isLetter else {
            return false
        }
        return labels.allSatisfy { label in
            (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Hands the helper the host names to block, or none while inactive. It re-reads the file every second.
    private func send() {
        guard case .running(let pid, let requests) = helper else { return }
        guard Self.isAlive(pid) else {
            // The next focus phase starts it again.
            helper = .stopped
            if isActive, !domains.isEmpty { problem = "Domains aren't blocked: the helper stopped." }
            return
        }
        // END marks the list as complete, so a read that lands mid-write is ignored instead of acted on.
        let list = (isActive ? hostNames : []) + ["END"]
        do {
            try Data((list.joined(separator: "\n") + "\n").utf8).write(to: requests)
            problem = nil
        } catch {
            problem = "Couldn't update the blocked domains: the helper isn't responding."
        }
    }

    private func startHelperIfNeeded() {
        switch helper {
        case .starting:
            return
        case .running(let pid, _) where Self.isAlive(pid):
            return
        default:
            break
        }
        helper = .starting
        problem = nil
        let appPID = getpid()
        Task {
            switch await Self.startHelper(appPID: appPID, userID: getuid()) {
            case .success(let helperPID):
                helper = .running(pid: helperPID, requests: Self.requestsDirectory.appending(path: "\(appPID)"))
                send()
            case .failure(let failure):
                problem = failure.message
                helper = .stopped
            }
        }
    }

    /// Whether a process exists. A root process answers EPERM, which still means it's there.
    private nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private struct Failure: Error {
        let message: String
    }

    /// Where the helper keeps the file it takes orders from, named after this app's process ID.
    private nonisolated static let requestsDirectory =
        URL(filePath: "/var/run/PomodoroBlocker", directoryHint: .isDirectory)

    /// Runs the helper as root and returns its process ID. macOS shows its own password prompt, which is why this
    /// goes through osascript: the dialog appears without freezing the menu bar while it waits.
    private nonisolated static func startHelper(appPID: pid_t, userID: uid_t) async -> Result<pid_t, Failure> {
        let osascript = Process()
        osascript.executableURL = URL(filePath: "/usr/bin/osascript")
        // Everything after the script reaches it as arguments, so nothing needs escaping on the way in.
        osascript.arguments = ["-e", elevate, helperScript, "PomodoroBlocker", "\(appPID)", "\(userID)"]
        let output = Pipe(), errors = Pipe()
        osascript.standardOutput = output
        osascript.standardError = errors
        do {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                osascript.terminationHandler = { _ in done.resume() }
                do { try osascript.run() } catch { done.resume(throwing: error) }
            }
        } catch {
            return .failure(Failure(message: "Domains aren't blocked: couldn't ask for permission."))
        }
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if osascript.terminationStatus == 0, let pid = pid_t(result.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .success(pid)
        }
        // -128 is AppleScript's "User canceled".
        return .failure(Failure(message: errorText.contains("-128")
            ? "Domains aren't blocked: administrator permission wasn't given."
            : "Domains aren't blocked: the helper couldn't start."))
    }

    /// Runs its first argument as a shell script with the rest as that script's arguments, as root.
    private nonisolated static let elevate = #"""
        on run argv
            set reason to "PomodoroBlocker needs to edit /etc/hosts to block domains during focus."
            set shellCommand to "/bin/sh -c " & quoted form of (item 1 of argv)
            repeat with i from 2 to count of argv
                set shellCommand to shellCommand & " " & quoted form of (item i of argv)
            end repeat
            do shell script shellCommand with prompt reason with administrator privileges
        end run
        """#

    /// Runs as root, as `sh -c <this> PomodoroBlocker <app pid> <user id>`, and prints the pid of the helper it
    /// leaves running. The helper looks at its request file once a second, and reads it only when it has changed,
    /// since a list can run to thousands. The file holds the host names to block one per line followed by END, and
    /// the helper keeps the block in /etc/hosts equal to them. The optional third and fourth arguments replace the
    /// hosts file and the directory for request files, to try it out on copies.
    private nonisolated static let helperScript = #"""
        export LC_ALL=C
        set -f
        app=$1 uid=$2 hosts=${3:-/etc/hosts} dir=${4:-/var/run/PomodoroBlocker}
        case $app$uid in '' | *[!0-9]*) exit 1 ;; esac
        req=$dir/$app work=$dir/$app.work

        # Prints the host names in file $1 that are valid, once each. A valid name is lowercase letters, digits and hyphens
        # in at least two labels, the last starting with a letter. Fails unless the file is complete, meaning it has its END
        # line, so a request caught mid-write is left for the next look.
        parse() {
            awk '
                $0 == "END" { done = 1; exit }
                length($0) <= 253 && /^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$/ && !seen[$0]++ { print }
                END { exit !done }
            ' "$1"
        }

        # Rewrites the block in the hosts file to cover the host names in file $1; an empty file removes it.
        apply() {
            # A start marker without its end marker means the block was edited by hand, so leave the file alone.
            if grep -q '^# BEGIN PomodoroBlocker' "$hosts" && ! grep -q '^# END PomodoroBlocker' "$hosts"; then
                return 1
            fi
            tmp=$(mktemp "$hosts.XXXXXX") || return 1
            awk '/^# BEGIN PomodoroBlocker/ { skip = 1 } !skip { print } /^# END PomodoroBlocker/ { skip = 0 }' \
                "$hosts" >"$tmp" || { rm -f "$tmp"; return 1; }
            if [ -s "$1" ]; then
                {
                    echo '# BEGIN PomodoroBlocker (removed when focus ends; delete these lines to unblock now)'
                    awk '{ print "0.0.0.0 " $0; print ":: " $0 }' "$1"
                    echo '# END PomodoroBlocker'
                } >>"$tmp"
            fi
            chown "$(stat -f %u:%g "$hosts")" "$tmp" && chmod "$(stat -f %Lp "$hosts")" "$tmp" && mv "$tmp" "$hosts" ||
                { rm -f "$tmp"; return 1; }
            dscacheutil -flushcache
            killall -HUP mDNSResponder
            cp "$1" "$work/applied"
            return 0
        }

        mkdir -p "$dir" && chmod 755 "$dir" && : >"$req" && chown "$uid" "$req" && chmod 600 "$req" &&
            rm -rf "$work" && mkdir -m 700 "$work" || exit 1
        (
            trap '' HUP
            trap 'apply /dev/null; rm -rf "$req" "$work"; exit 0' TERM INT
            apply /dev/null
            : >"$work/last"
            while kill -0 "$app" 2>/dev/null; do
                # The request is only read when it differs from the last one dealt with, as lists can run to thousands.
                if ! cmp -s "$req" "$work/last"; then
                    cp "$req" "$work/snap"
                    if parse "$work/snap" >"$work/names" && { cmp -s "$work/names" "$work/applied" || apply "$work/names"; }; then
                        cp "$work/snap" "$work/last"
                    fi
                fi
                sleep 1
            done
            apply /dev/null
            rm -rf "$req" "$work"
        ) >/dev/null 2>&1 </dev/null &
        echo $!
        """#
}
