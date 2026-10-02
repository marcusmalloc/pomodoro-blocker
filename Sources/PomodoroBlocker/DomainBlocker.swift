import CryptoKit
import Darwin
import DomainBlocking
import Foundation
import Observation

/// Installs a root-owned launchd helper once, then reuses it across app launches.
/// Domain-only requests expire after ten seconds to clear blocks after a crash.
@MainActor
@Observable
final class DomainBlocker {
    var domains: [String] = [] {
        didSet {
            guard domains != oldValue else { return }
            if domains.isEmpty { problem = nil }
            send()
        }
    }
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive, !domains.isEmpty { startHelperIfNeeded() }
            send()
        }
    }
    private(set) var problem: String?
    private enum Helper { case stopped, starting, ready }
    @ObservationIgnored private var helper = Helper.stopped
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var request: DomainRequest?
    @ObservationIgnored private var sentAt = Date.distantPast
    @ObservationIgnored private var lastHeartbeat = Date.distantPast

    private var hostNames: [String] { domains.flatMap { [$0, "www.\($0)"] } }

    nonisolated static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split { $0.isWhitespace || $0 == "," || $0 == ";" }
            .compactMap { domain(in: String($0)) }.filter { seen.insert($0).inserted }
    }
    private nonisolated static func domain(in entry: String) -> String? {
        guard var host = URL(string: entry.contains("://") ? entry : "https://\(entry)")?.host()?.lowercased() else {
            return nil
        }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host.removeFirst(4) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2, labels.last!.count >= 2, labels.last!.first!.isLetter,
              labels.allSatisfy({ label in
                  (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                      && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
              }) else { return nil }
        return host
    }
    private func send() {
        guard case .ready = helper, let process = ProcessIdentity.current() else { return }
        let now = Date()
        request = DomainRequest(id: UUID().uuidString, process: process,
                                hostNames: isActive ? hostNames : [], expiresAt: now.timeIntervalSince1970 + 10)
        sentAt = now
        if isActive, !domains.isEmpty { problem = "Applying website block…" }
        writeHeartbeat()
    }
    private func writeHeartbeat() {
        guard let request else { return }
        let now = Date()
        let renewed = DomainRequest(id: request.id, process: request.process,
                                    hostNames: request.hostNames, expiresAt: now.timeIntervalSince1970 + 10)
        do {
            try Self.write(renewed)
            lastHeartbeat = now
        } catch {
            if isActive, !domains.isEmpty { problem = Self.unavailable }
        }
    }
    private func checkResponse() {
        guard let request else { return }
        let url = DomainHelperPaths.directory(for: getuid()).appending(path: "status.json")
        if let info = Self.trustedFile(url),
           Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) < 5,
           let data = try? Data(contentsOf: url), data.count <= 16_384,
           let response = try? JSONDecoder().decode(DomainResponse.self, from: data),
           response.version == DomainHelperPaths.version, response.requestID == request.id {
            problem = response.problem
        } else if Date().timeIntervalSince(sentAt) > 3, isActive, !domains.isEmpty {
            problem = Self.unavailable
        }
    }
    private func startHelperIfNeeded() {
        guard case .stopped = helper else { return }
        helper = .starting
        problem = nil
        Task {
            let result = await Task.detached { await Self.ensureHelper(userID: getuid()) }.value
            switch result {
            case .success:
                helper = .ready
                send()
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        guard !Task.isCancelled, let self else { return }
                        if Date().timeIntervalSince(self.lastHeartbeat) >= 2 { self.writeHeartbeat() }
                        self.checkResponse()
                    }
                }
            case .failure(let failure):
                helper = .stopped
                problem = failure.message
            }
        }
    }
    private struct Failure: Error, Sendable { let message: String }
    private nonisolated static let unavailable =
        "Website blocking isn't available. Check PomodoroBlocker in System Settings → Login Items."

    private nonisolated static func trustedFile(_ url: URL) -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0 else { return nil }
        return info
    }
    private nonisolated static func isInstalled(userID: uid_t) -> Bool {
        guard let binary = trustedFile(URL(filePath: DomainHelperPaths.executable)),
              binary.st_mode & 0o111 != 0,
              trustedFile(URL(filePath: DomainHelperPaths.plist(for: userID))) != nil,
              let data = try? Data(contentsOf: URL(filePath: DomainHelperPaths.plist(for: userID))),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return plist["Label"] as? String == DomainHelperPaths.label(for: userID)
            && plist["ProgramArguments"] as? [String] == [DomainHelperPaths.executable, "\(userID)"]
            && plist["KeepAlive"] as? Bool == true && plist["RunAtLoad"] as? Bool == true
    }
    /// An installed but disabled helper reports an error instead of asking for permission again.
    private nonisolated static func ensureHelper(userID: uid_t) async -> Result<Void, Failure> {
        if !isInstalled(userID: userID) {
            guard let binary = Bundle.main.resourceURL?.appending(path: "PomodoroDomainHelper"),
                  let contents = try? Data(contentsOf: binary) else {
                return .failure(Failure(message: "Website blocking helper is missing. Reinstall PomodoroBlocker."))
            }
            let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            let osascript = Process()
            osascript.executableURL = URL(filePath: "/usr/bin/osascript")
            osascript.arguments = ["-e", elevate, installScript, "PomodoroBlocker", "\(userID)", binary.path, digest]
            let errors = Pipe()
            osascript.standardOutput = FileHandle.nullDevice
            osascript.standardError = errors
            do {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                    osascript.terminationHandler = { _ in done.resume() }
                    do { try osascript.run() } catch { done.resume(throwing: error) }
                }
            } catch {
                return .failure(Failure(message: "Domains aren't blocked: couldn't ask for permission."))
            }
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard osascript.terminationStatus == 0, isInstalled(userID: userID) else {
                return .failure(Failure(message: errorText.contains("-128")
                    ? "Domains aren't blocked: administrator permission wasn't given."
                    : "Domains aren't blocked: the website blocking helper couldn't be installed."))
            }
        }
        for _ in 0..<24 {
            let directory = DomainHelperPaths.directory(for: userID)
            let status = directory.appending(path: "status.json")
            if let info = trustedFile(status),
               Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) < 5,
               let data = try? Data(contentsOf: status), data.count <= 16_384,
               let response = try? JSONDecoder().decode(DomainResponse.self, from: data),
               response.version == DomainHelperPaths.version,
               FileManager.default.isWritableFile(atPath: directory.appending(path: "request.json").path) {
                return .success(())
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .failure(Failure(message: unavailable))
    }
    private nonisolated static func write(_ request: DomainRequest) throws {
        let directory = DomainHelperPaths.directory(for: request.process.uid)
        var parent = stat()
        guard lstat(directory.path, &parent) == 0, parent.st_uid == 0,
              parent.st_mode & S_IFMT == S_IFDIR, parent.st_mode & 0o022 == 0 else {
            throw Failure(message: "Unsafe request directory.")
        }
        let fd = open(directory.appending(path: "request.json").path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure(message: "Request file unavailable.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == request.process.uid, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure(message: "Unsafe request file.") }
        defer { flock(fd, LOCK_UN) }
        let data = try JSONEncoder().encode(request)
        guard data.count <= 1_048_576, ftruncate(fd, 0) == 0 else { throw Failure(message: "Request too large.") }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Failure(message: "Couldn't write request.") }
                offset += written
            }
        }
    }
    private nonisolated static let elevate = #"""
        on run argv
            set reason to "PomodoroBlocker needs to install its website blocking helper. This permission is only needed once."
            set shellCommand to "/bin/sh -c " & quoted form of (item 1 of argv)
            repeat with i from 2 to count of argv
                set shellCommand to shellCommand & " " & quoted form of (item i of argv)
            end repeat
            do shell script shellCommand with prompt reason with administrator privileges
        end run
        """#
    private nonisolated static let installScript = #"""
        set -eu
        PATH=/usr/bin:/bin:/usr/sbin:/sbin
        export PATH
        uid=$1 source=$2 digest=$3
        case "$uid" in ''|*[!0-9]*) exit 1 ;; esac
        case "$digest" in *[!a-f0-9]*|'') exit 1 ;; esac
        [ "${#digest}" -eq 64 ] && [ "$(id -u)" -eq 0 ] || exit 1
        label=com.marcusmalloc.pomodoroblocker.domains.$uid
        helper=/Library/PrivilegedHelperTools/com.marcusmalloc.pomodoroblocker.domains
        plist=/Library/LaunchDaemons/$label.plist
        trusted() {
            [ ! -L "$1" ] && [ "$(stat -f %u "$1")" -eq 0 ] || return 1
            mode=$(stat -f %Lp "$1") || return 1
            [ $((0$mode & 0022)) -eq 0 ]
        }
        for parent in /Library /Library/LaunchDaemons /Library/PrivilegedHelperTools; do
            if [ ! -e "$parent" ]; then mkdir -m 755 "$parent"; chown root:wheel "$parent"; fi
            [ -d "$parent" ] && trusted "$parent" || exit 1
        done
        for file in "$helper" "$plist"; do
            if [ -e "$file" ] || [ -L "$file" ]; then [ -f "$file" ] && trusted "$file" || exit 1; fi
        done
        staging=$(mktemp -d /Library/PrivilegedHelperTools/.PomodoroBlocker.XXXXXX)
        trap 'rm -rf "$staging"' EXIT
        /usr/bin/install -m 755 -o root -g wheel "$source" "$staging/helper"
        [ "$(shasum -a 256 "$staging/helper" | awk '{print $1}')" = "$digest" ] || exit 1
        cat >"$staging/daemon.plist" <<EOF
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>$label</string>
        <key>ProgramArguments</key><array><string>$helper</string><string>$uid</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>ThrottleInterval</key><integer>2</integer>
        </dict></plist>
        EOF
        chown root:wheel "$staging/daemon.plist"
        chmod 644 "$staging/daemon.plist"
        plutil -lint "$staging/daemon.plist" >/dev/null
        launchctl bootout "system/$label" >/dev/null 2>&1 || true
        mv "$staging/helper" "$helper"
        mv "$staging/daemon.plist" "$plist"
        launchctl enable "system/$label"
        launchctl bootstrap system "$plist"
        """#
}
