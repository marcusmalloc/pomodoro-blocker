import Darwin
import Foundation

/// Paths shared by the app and its installed privileged helper.
public enum DomainHelperPaths {
    public static let version = 1
    public static let executable = "/Library/PrivilegedHelperTools/com.marcusmalloc.pomodoroblocker.domains"

    public static func label(for uid: uid_t) -> String {
        "com.marcusmalloc.pomodoroblocker.domains.\(uid)"
    }

    public static func plist(for uid: uid_t) -> String {
        "/Library/LaunchDaemons/\(label(for: uid)).plist"
    }

    public static func directory(for uid: uid_t) -> URL {
        URL(filePath: "/var/run/PomodoroBlocker-\(uid)", directoryHint: .isDirectory)
    }
}

/// A PID together with its owner and kernel-recorded creation time. A reused PID cannot inherit a block.
public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: pid_t
    public var uid: uid_t
    public var startedSeconds: UInt64
    public var startedMicroseconds: UInt64

    public init(pid: pid_t, uid: uid_t, startedSeconds: UInt64, startedMicroseconds: UInt64) {
        self.pid = pid
        self.uid = uid
        self.startedSeconds = startedSeconds
        self.startedMicroseconds = startedMicroseconds
    }

    public static func current() -> Self? {
        identity(for: getpid())
    }

    public func matchesRunningProcess() -> Bool {
        guard pid > 0 else { return false }
        return Self.identity(for: pid) == self
    }

    private static func identity(for pid: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(
            pid: pid,
            uid: info.pbi_uid,
            startedSeconds: info.pbi_start_tvsec,
            startedMicroseconds: info.pbi_start_tvusec
        )
    }
}

/// A short lease means blocks are removed even if the app stops responding without exiting.
public struct DomainRequest: Codable, Equatable, Sendable {
    public var version: Int = DomainHelperPaths.version
    public var id: String
    public var process: ProcessIdentity
    public var hostNames: [String]
    public var expiresAt: TimeInterval

    public init(id: String, process: ProcessIdentity, hostNames: [String], expiresAt: TimeInterval) {
        self.id = id
        self.process = process
        self.hostNames = hostNames
        self.expiresAt = expiresAt
    }

    public func isValid(for uid: uid_t, now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        version == DomainHelperPaths.version
            && UUID(uuidString: id) != nil
            && process.uid == uid
            && process.pid > 0
            && process.startedSeconds > 0
            && process.startedMicroseconds < 1_000_000
            && hostNames.count <= HostName.maximumCount
            && hostNames.allSatisfy(HostName.isValid)
            && now.isFinite
            && expiresAt.isFinite
            && expiresAt > now
            && expiresAt <= now + 15
    }
}

public struct DomainResponse: Codable, Equatable, Sendable {
    public var version: Int = DomainHelperPaths.version
    public var requestID: String?
    public var problem: String?

    public init(requestID: String?, problem: String?) {
        self.requestID = requestID
        self.problem = problem
    }
}

private enum HostName {
    static let maximumCount = 20_000

    static func isValid(_ host: String) -> Bool {
        let bytes = Array(host.utf8)
        guard !bytes.isEmpty, bytes.count <= 253,
              bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 })
        else { return false }
        let labels = bytes.split(separator: 46, omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last,
              last.count >= 2, let first = last.first, (97...122).contains(first)
        else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.count) && label.first != 45 && label.last != 45
        }
    }
}

public enum HostsFileError: Error, Equatable, LocalizedError {
    case invalidHostNames
    case malformedMarkers

    public var errorDescription: String? {
        switch self {
        case .invalidHostNames: "The domain list contains an invalid host name."
        case .malformedMarkers: "The PomodoroBlocker section in /etc/hosts has incomplete or conflicting markers."
        }
    }
}

/// Pure hosts-file rendering. File permissions, atomic replacement and cache flushing belong to the helper.
public enum HostsFile {
    public static func updated(_ existing: String, hostNames: [String], uid: uid_t) throws -> String {
        guard hostNames.count <= HostName.maximumCount, hostNames.allSatisfy(HostName.isValid) else {
            throw HostsFileError.invalidHostNames
        }
        let ownBegin = "# BEGIN PomodoroBlocker uid=\(uid)"
        let ownEnd = "# END PomodoroBlocker uid=\(uid)"
        let legacyBegin = "# BEGIN PomodoroBlocker (removed when focus ends; delete these lines to unblock now)"
        let legacyEnd = "# END PomodoroBlocker"
        var expectedEnd: String?
        var preserved: [String] = []
        var ownPosition: Int?
        var legacyPosition: Int?

        // Keep each original line ending so entries outside our section are preserved byte for byte.
        let bytes = Array(existing.utf8)
        var cursor = 0
        while cursor < bytes.count {
            let end = bytes[cursor...].firstIndex(of: 10).map { $0 + 1 } ?? bytes.count
            let original = String(decoding: bytes[cursor..<end], as: UTF8.self)
            var contentEnd = end
            if contentEnd > cursor, bytes[contentEnd - 1] == 10 { contentEnd -= 1 }
            if contentEnd > cursor, bytes[contentEnd - 1] == 13 { contentEnd -= 1 }
            let line = String(decoding: bytes[cursor..<contentEnd], as: UTF8.self)

            if let closing = expectedEnd {
                if line == closing {
                    expectedEnd = nil
                } else if isMarker(line) {
                    // A nested section could belong to someone else. Never discard its contents.
                    throw HostsFileError.malformedMarkers
                }
            } else if line == ownBegin {
                if ownPosition == nil { ownPosition = preserved.count }
                expectedEnd = ownEnd
            } else if line == legacyBegin {
                if legacyPosition == nil { legacyPosition = preserved.count }
                expectedEnd = legacyEnd
            } else if line == ownEnd || line == legacyEnd || malformedOwnedMarker(line, uid: uid) {
                throw HostsFileError.malformedMarkers
            } else {
                preserved.append(original)
            }
            cursor = end
        }
        guard expectedEnd == nil else { throw HostsFileError.malformedMarkers }

        var seen = Set<String>()
        let names = hostNames.filter { seen.insert($0).inserted }
        if !names.isEmpty {
            var block = ownBegin + "\n"
            for name in names {
                block += "0.0.0.0 \(name)\n:: \(name)\n"
            }
            block += ownEnd + "\n"
            if let position = ownPosition ?? legacyPosition {
                // Keep existing sections in place so helpers for different users do not keep moving each
                // other's sections, rewriting /etc/hosts and flushing DNS despite unchanged domains.
                preserved.insert(block, at: position)
            } else {
                if let last = preserved.last, last.utf8.last != 10 { preserved.append("\n") }
                preserved.append(block)
            }
        }
        return preserved.joined()
    }

    private static func isMarker(_ line: String) -> Bool {
        line.hasPrefix("# BEGIN PomodoroBlocker") || line.hasPrefix("# END PomodoroBlocker")
    }

    private static func malformedOwnedMarker(_ line: String, uid: uid_t) -> Bool {
        for prefix in ["# BEGIN PomodoroBlocker", "# END PomodoroBlocker"] where line.hasPrefix(prefix) {
            let remainder = line.dropFirst(prefix.count)
            // All global markers belong to the legacy format; only its exact paired markers are accepted.
            guard remainder.hasPrefix(" uid=") else { return true }
            let uidPart = remainder.dropFirst(" uid=".count)
            let digits = uidPart.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let markerUID = uid_t(digits) else { return true }
            if markerUID == uid { return true }
        }
        return false
    }
}
