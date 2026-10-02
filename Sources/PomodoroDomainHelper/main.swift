import Darwin
import Dispatch
import DomainBlocking
import Foundation

private struct HelperFailure: Error, CustomStringConvertible {
    let description: String
}

private func failure(_ action: String) -> HelperFailure {
    HelperFailure(description: "\(action): \(String(cString: strerror(errno)))")
}

private let maximumRequestBytes = 1_048_576
private let maximumHostsBytes = 4_194_304

private func metadata(_ fd: Int32) throws -> stat {
    var value = stat()
    guard fstat(fd, &value) == 0 else { throw failure("Couldn't inspect a file") }
    return value
}

private func isRegular(_ value: stat) -> Bool {
    (value.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
}

private func sameFile(_ left: stat, _ right: stat) -> Bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_size == right.st_size
        && left.st_uid == right.st_uid && left.st_gid == right.st_gid && left.st_mode == right.st_mode
        && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
        && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
}

private func readAll(_ fd: Int32, limit: Int) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fd, bytes.baseAddress, bytes.count)
        }
        if count == 0 { return result }
        if count < 0 {
            if errno == EINTR { continue }
            throw failure("Couldn't read a file")
        }
        guard result.count <= limit - count else {
            throw HelperFailure(description: "The file exceeds its allowed size.")
        }
        result.append(contentsOf: buffer.prefix(count))
    }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var position = 0
        while position < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), bytes.count - position)
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("Couldn't write a file")
            }
            guard count > 0 else { throw HelperFailure(description: "A file write made no progress.") }
            position += count
        }
    }
}

/// Requests are the only user-writable object under this root-owned directory. Holding its descriptor and
/// opening relative to it prevents a request pathname from redirecting privileged reads or writes elsewhere.
private final class RequestDirectory {
    let fd: Int32
    let userID: uid_t
    let ownerID: uid_t

    init(path: String, userID: uid_t, testing: Bool) throws {
        self.userID = userID
        ownerID = testing ? geteuid() : 0

        // Test mode requires an explicitly prepared directory. Production may create its fixed /var/run path.
        var createdDirectory = false
        if !testing {
            if mkdir(path, 0o755) == 0 {
                createdDirectory = true
            } else if errno != EEXIST {
                throw failure("Couldn't create the helper directory")
            }
        }
        fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("Couldn't open the helper directory") }
        do {
            if createdDirectory, fchmod(fd, 0o755) != 0 { throw failure("Couldn't protect the helper directory") }
            let value = try metadata(fd)
            guard value.st_uid == ownerID, (value.st_mode & 0o7777) == 0o755 else {
                throw HelperFailure(description: "The helper directory has unsafe ownership or permissions.")
            }
            try prepareRequest()
        } catch {
            close(fd)
            throw error
        }
    }

    deinit { close(fd) }

    private func prepareRequest() throws {
        let created = openat(fd, "request.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if created >= 0 {
            defer { close(created) }
            if !testingOwner, fchown(created, userID, gid_t.max) != 0 {
                throw failure("Couldn't assign the request file to its user")
            }
            guard fchmod(created, 0o600) == 0 else { throw failure("Couldn't protect the request file") }
        } else if errno != EEXIST {
            throw failure("Couldn't create the request file")
        }
        let request = try openRequest()
        close(request)
        // Reject unexpected artifacts rather than following them, including symlinks left by an older setup.
        var existing = stat()
        if fstatat(fd, "status.json", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard isRegular(existing), existing.st_uid == ownerID, existing.st_nlink == 1,
                  (existing.st_mode & 0o7777) == 0o644 else {
                throw HelperFailure(description: "The helper status file has unsafe ownership or permissions.")
            }
        } else if errno != ENOENT {
            throw failure("Couldn't inspect the helper status file")
        }
    }

    private var testingOwner: Bool { ownerID != 0 }

    private func openRequest() throws -> Int32 {
        let request = openat(fd, "request.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard request >= 0 else { throw failure("Couldn't open the domain request") }
        do {
            let value = try metadata(request)
            guard isRegular(value), value.st_uid == userID, value.st_nlink == 1,
                  (value.st_mode & 0o7777) == 0o600 else {
                throw HelperFailure(description: "The domain request has unsafe ownership or permissions.")
            }
            return request
        } catch {
            close(request)
            throw error
        }
    }

    enum Snapshot {
        case busy
        case empty
        case request(DomainRequest)
    }

    func snapshot() throws -> Snapshot {
        let request = try openRequest()
        defer { close(request) }
        if flock(request, LOCK_SH | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return .busy }
            throw failure("Couldn't read the domain request safely")
        }
        defer { flock(request, LOCK_UN) }
        let before = try metadata(request)
        guard before.st_size >= 0, before.st_size <= maximumRequestBytes else {
            throw HelperFailure(description: "The domain request exceeds its allowed size.")
        }
        let data = try readAll(request, limit: maximumRequestBytes)
        guard sameFile(before, try metadata(request)) else { return .busy }
        guard !data.isEmpty else { return .empty }
        do {
            return .request(try JSONDecoder().decode(DomainRequest.self, from: data))
        } catch {
            throw HelperFailure(description: "The domain request is incomplete or malformed.")
        }
    }

    func respond(requestID: String?, problem: String?) throws {
        var data = try JSONEncoder().encode(DomainResponse(requestID: requestID, problem: problem))
        data.append(0x0a)
        let temporary = ".status-\(UUID().uuidString)"
        let status = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard status >= 0 else { throw failure("Couldn't write the helper status") }
        defer {
            close(status)
            unlinkat(fd, temporary, 0)
        }
        guard fchmod(status, 0o644) == 0 else { throw failure("Couldn't protect the helper status") }
        try writeAll(data, to: status)
        guard renameat(fd, temporary, fd, "status.json") == 0 else { throw failure("Couldn't publish the helper status") }
    }
}

private final class HostsWriter {
    let path: String
    let userID: uid_t
    let testing: Bool
    private var needsDNSRefresh = false

    init(path: String, userID: uid_t, testing: Bool) {
        self.path = path
        self.userID = userID
        self.testing = testing
    }

    func apply(_ names: [String]) throws {
        let url = URL(filePath: path)
        // /etc is a system symlink on macOS. Resolve its parent while refusing a symlink for hosts itself.
        let parentPath = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let parent = open(parentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure("Couldn't open the hosts directory") }
        defer { close(parent) }
        if !testing {
            let directory = try metadata(parent)
            guard directory.st_uid == 0, (directory.st_mode & 0o022) == 0 else {
                throw HelperFailure(description: "The hosts directory has unsafe ownership or permissions.")
            }
        }
        let filename = url.lastPathComponent
        let hosts = openat(parent, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard hosts >= 0 else { throw failure("Couldn't read the hosts file") }
        defer { close(hosts) }
        let before = try metadata(hosts)
        guard isRegular(before), before.st_size >= 0, before.st_size <= maximumHostsBytes else {
            throw HelperFailure(description: "The hosts file is not a supported regular file.")
        }
        if !testing, before.st_uid != 0 {
            throw HelperFailure(description: "The hosts file is not owned by root.")
        }
        let existingData = try readAll(hosts, limit: maximumHostsBytes)
        guard sameFile(before, try metadata(hosts)), let existing = String(data: existingData, encoding: .utf8) else {
            throw HelperFailure(description: "The hosts file changed while being read or isn't valid text.")
        }
        let updated = try HostsFile.updated(existing, hostNames: names, uid: userID)
        if updated != existing {
            let updatedData = Data(updated.utf8)
            guard updatedData.count <= maximumHostsBytes else {
                throw HelperFailure(description: "The requested hosts update exceeds its allowed size.")
            }
            let temporary = ".pomodoro-hosts-\(UUID().uuidString)"
            let replacement = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard replacement >= 0 else { throw failure("Couldn't prepare the hosts update") }
            defer {
                close(replacement)
                unlinkat(parent, temporary, 0)
            }
            try writeAll(updatedData, to: replacement)
            guard fchown(replacement, before.st_uid, before.st_gid) == 0,
                  fchmod(replacement, before.st_mode & 0o7777) == 0,
                  fsync(replacement) == 0 else {
                throw failure("Couldn't preserve the hosts file's ownership and permissions")
            }
            var current = stat()
            guard fstatat(parent, filename, &current, AT_SYMLINK_NOFOLLOW) == 0, sameFile(before, current) else {
                throw HelperFailure(description: "The hosts file changed before the update could be applied.")
            }
            guard renameat(parent, temporary, parent, filename) == 0 else { throw failure("Couldn't apply the hosts update") }
            needsDNSRefresh = !testing
        }
        if needsDNSRefresh {
            try refreshDNS()
            needsDNSRefresh = false
        }
    }

    private func refreshDNS() throws {
        for (executable, arguments) in [
            ("/usr/bin/dscacheutil", ["-flushcache"]),
            ("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        ] {
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw HelperFailure(description: "Couldn't refresh the DNS cache.") }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw HelperFailure(description: "Couldn't refresh the DNS cache.") }
        }
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

private func report(_ message: String) {
    FileHandle.standardError.write(Data("PomodoroDomainHelper: \(message)\n".utf8))
}

private func run(userID: uid_t, hostsPath: String, directoryPath: String, testing: Bool) throws {
    let hosts = HostsWriter(path: hostsPath, userID: userID, testing: testing)
    // A restarted daemon must first undo a block left by a crash, before it trusts any prior request.
    var startupProblem: String?
    do { try hosts.apply([]) } catch { startupProblem = String(describing: error) }
    let directory = try RequestDirectory(path: directoryPath, userID: userID, testing: testing)
    try directory.respond(requestID: nil, problem: startupProblem)

    let stopped = StopFlag()
    let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { stopped.stop() }
        source.resume()
        return source
    }
    defer { for source in signals { source.cancel() } }
    var lastRequest: DomainRequest?

    while !stopped.isStopped {
        var problem: String?
        var requestID: String?
        var names: [String] = []
        do {
            switch try directory.snapshot() {
            case .busy: break // The writer holds its lock. A cached request still needs its live lease below.
            case .empty: lastRequest = nil
            case .request(let request): lastRequest = request
            }
            if let request = lastRequest {
                if UUID(uuidString: request.id) != nil { requestID = request.id }
                if request.isValid(for: userID), request.process.matchesRunningProcess() {
                    names = request.hostNames
                } else {
                    problem = "The app's domain request expired or is no longer valid."
                    lastRequest = nil
                }
            }
        } catch {
            lastRequest = nil
            problem = String(describing: error)
        }
        do {
            // Reading the real hosts content each time also repairs a block removed by an old helper or editor.
            try hosts.apply(names)
        } catch {
            problem = "Couldn't update the hosts file: \(error)"
        }
        do {
            // Refresh the timestamp even for identical acknowledgments so the app can detect daemon death.
            try directory.respond(requestID: requestID, problem: problem)
        } catch { report(String(describing: error)) }
        Thread.sleep(forTimeInterval: 0.5)
    }
    do {
        try hosts.apply([])
        try directory.respond(requestID: nil, problem: nil)
    } catch { report("Couldn't remove domain blocks while stopping: \(error)") }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let testing = arguments.first == "--test"
let userText = testing ? arguments.dropFirst().first : arguments.first
guard let userText, !userText.isEmpty, userText.allSatisfy({ $0.isASCII && $0.isNumber }),
      let userID = uid_t(userText), userID > 0 else {
    report("Expected a numeric user ID.")
    exit(EXIT_FAILURE)
}
let hostsPath: String
let directoryPath: String
if testing {
    guard geteuid() != 0, arguments.count == 4, userID == getuid() else {
        report("Test mode requires an unprivileged process, its own user ID, hosts file and prepared directory.")
        exit(EXIT_FAILURE)
    }
    hostsPath = arguments[2]
    directoryPath = arguments[3]
} else {
    guard geteuid() == 0, arguments.count == 1 else {
        report("The installed helper must run as root with only its authorized user ID.")
        exit(EXIT_FAILURE)
    }
    hostsPath = "/etc/hosts"
    directoryPath = DomainHelperPaths.directory(for: userID).path
}
do {
    try run(userID: userID, hostsPath: hostsPath, directoryPath: directoryPath, testing: testing)
} catch {
    report(String(describing: error))
    exit(EXIT_FAILURE)
}
