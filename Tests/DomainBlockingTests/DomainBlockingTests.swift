import Darwin
import Foundation
import XCTest
@testable import DomainBlocking

final class DomainBlockingTests: XCTestCase {
    private let uid: uid_t = 501
    private let now: TimeInterval = 1_800_000_000

    private func request(_ hosts: [String] = ["example.com"]) -> DomainRequest {
        DomainRequest(
            id: UUID().uuidString,
            process: ProcessIdentity(pid: 123, uid: uid, startedSeconds: 1_799_000_000, startedMicroseconds: 100),
            hostNames: hosts,
            expiresAt: now + 10
        )
    }

    func testRequestAcceptsStrictHostNamesAndEmptyBlock() {
        XCTAssertTrue(request(["example.com", "www.example.com", "xn--bcher-kva.de", "a-b.c2"]).isValid(for: uid, now: now))
        XCTAssertTrue(request([]).isValid(for: uid, now: now))
        XCTAssertTrue(request(["example.com", "example.com"]).isValid(for: uid, now: now))
    }

    func testRejectsInjectionAndInvalidHostNames() {
        let invalid = [
            "example.com\n127.0.0.1 localhost", "example.com # comment", "example.com\tlocalhost",
            "Example.com", "bücher.de", "127.0.0.1", "::1", "localhost", "example.c", "example.2a",
            "example..com", "-example.com", "example-.com", "example.com.", ".example.com", "*.example.com",
            "https://example.com", "example_com.net", String(repeating: "a", count: 64) + ".com",
            Array(repeating: String(repeating: "a", count: 63), count: 4).joined(separator: "."),
        ]
        for host in invalid {
            XCTAssertFalse(request([host]).isValid(for: uid, now: now), host)
            XCTAssertThrowsError(try HostsFile.updated("127.0.0.1 localhost\n", hostNames: [host], uid: uid), host)
        }
    }

    func testRequestRejectsWrongVersionOwnerIDAndUnboundedLease() {
        var value = request()
        value.version += 1
        XCTAssertFalse(value.isValid(for: uid, now: now))
        value = request()
        value.id = "not-a-request-id"
        XCTAssertFalse(value.isValid(for: uid, now: now))
        XCTAssertFalse(request().isValid(for: uid + 1, now: now))
        value = request()
        value.process.pid = 0
        XCTAssertFalse(value.isValid(for: uid, now: now))
        value = request()
        value.process.startedMicroseconds = 1_000_000
        XCTAssertFalse(value.isValid(for: uid, now: now))
        for expiration in [now - 1, now, now + 15.01, .infinity, .nan] {
            value = request()
            value.expiresAt = expiration
            XCTAssertFalse(value.isValid(for: uid, now: now))
        }
        value = request()
        value.expiresAt = now + 15
        XCTAssertTrue(value.isValid(for: uid, now: now))
        XCTAssertFalse(value.isValid(for: uid, now: .nan))
    }

    func testRejectsExcessiveHostList() {
        let hosts = Array(repeating: "example.com", count: 20_001)
        XCTAssertFalse(request(hosts).isValid(for: uid, now: now))
        XCTAssertThrowsError(try HostsFile.updated("", hostNames: hosts, uid: uid))
    }

    func testProcessIdentityMatchesCurrentProcessAndRejectsStaleIdentity() throws {
        let identity = try XCTUnwrap(ProcessIdentity.current())
        XCTAssertEqual(identity.pid, getpid())
        XCTAssertEqual(identity.uid, getuid())
        XCTAssertTrue(identity.matchesRunningProcess())
        var stale = identity
        stale.startedMicroseconds += 1
        XCTAssertFalse(stale.matchesRunningProcess())
        var wrongOwner = identity
        wrongOwner.uid += 1
        XCTAssertFalse(wrongOwner.matchesRunningProcess())
        XCTAssertFalse(ProcessIdentity(pid: -1, uid: getuid(), startedSeconds: 1, startedMicroseconds: 0).matchesRunningProcess())
    }

    func testRequestAndResponseJSONRoundTrip() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let original = request()
        XCTAssertEqual(try decoder.decode(DomainRequest.self, from: encoder.encode(original)), original)
        let response = DomainResponse(requestID: original.id, problem: nil)
        XCTAssertEqual(try decoder.decode(DomainResponse.self, from: encoder.encode(response)), response)
    }

    func testHostsLifecyclePreservesUnrelatedEntriesAndDeduplicates() throws {
        let original = "# System entries\n127.0.0.1 localhost\n::1 localhost\n192.0.2.1 private.example\n"
        let active = try HostsFile.updated(original, hostNames: ["example.com", "example.com", "www.example.com"], uid: uid)
        XCTAssertEqual(active, original + "# BEGIN PomodoroBlocker uid=501\n0.0.0.0 example.com\n:: example.com\n0.0.0.0 www.example.com\n:: www.example.com\n# END PomodoroBlocker uid=501\n")
        XCTAssertEqual(try HostsFile.updated(active, hostNames: ["example.com", "www.example.com"], uid: uid), active)
        let edited = try HostsFile.updated(active, hostNames: ["new.example"], uid: uid)
        XCTAssertFalse(edited.contains("0.0.0.0 example.com"))
        XCTAssertTrue(edited.contains("0.0.0.0 new.example\n:: new.example\n"))
        XCTAssertEqual(try HostsFile.updated(edited, hostNames: [], uid: uid), original)
    }

    func testPreservesOtherUsersSectionAndLineEndings() throws {
        let other = "# BEGIN PomodoroBlocker uid=502\r\n0.0.0.0 other.example\r\n:: other.example\r\n# END PomodoroBlocker uid=502\r\n"
        let original = "127.0.0.1 localhost\r\n" + other + "# unrelated trailing comment\r\n"
        let active = try HostsFile.updated(original, hostNames: ["example.com"], uid: uid)
        XCTAssertTrue(active.hasPrefix(original))
        XCTAssertEqual(try HostsFile.updated(active, hostNames: [], uid: uid), original)
        XCTAssertEqual(try HostsFile.updated(original, hostNames: [], uid: uid), original)
    }

    func testConcurrentUsersKeepSectionsInPlaceAcrossRefreshes() throws {
        let original = "127.0.0.1 localhost\n"
        let firstActive = try HostsFile.updated(original, hostNames: ["first.example"], uid: 501)
        let bothActive = try HostsFile.updated(firstActive, hostNames: ["second.example"], uid: 502)
        XCTAssertEqual(try HostsFile.updated(bothActive, hostNames: ["first.example"], uid: 501), bothActive)
        XCTAssertEqual(try HostsFile.updated(bothActive, hostNames: ["second.example"], uid: 502), bothActive)

        let changed = try HostsFile.updated(bothActive, hostNames: ["changed.example"], uid: 501)
        let expected = try HostsFile.updated(original, hostNames: ["changed.example"], uid: 501)
            + "# BEGIN PomodoroBlocker uid=502\n0.0.0.0 second.example\n:: second.example\n# END PomodoroBlocker uid=502\n"
        XCTAssertEqual(changed, expected)
        XCTAssertEqual(try HostsFile.updated(changed, hostNames: ["changed.example"], uid: 501), changed)
        XCTAssertEqual(try HostsFile.updated(changed, hostNames: ["second.example"], uid: 502), changed)
    }

    func testMigratesOnlyCompleteLegacySection() throws {
        let original = "127.0.0.1 localhost\n"
        let legacy = original + "# BEGIN PomodoroBlocker (removed when focus ends; delete these lines to unblock now)\n0.0.0.0 old.example\n:: old.example\n# END PomodoroBlocker\n"
        let updated = try HostsFile.updated(legacy, hostNames: ["new.example"], uid: uid)
        XCTAssertFalse(updated.contains("old.example"))
        XCTAssertTrue(updated.contains("# BEGIN PomodoroBlocker uid=501\n"))
        XCTAssertEqual(try HostsFile.updated(legacy, hostNames: [], uid: uid), original)
    }

    func testRefusesIncompleteConflictingAndMalformedMarkers() {
        let malformed = [
            "# BEGIN PomodoroBlocker uid=501\n0.0.0.0 example.com\n",
            "# END PomodoroBlocker uid=501\n",
            "# BEGIN PomodoroBlocker uid=501 extra\n# END PomodoroBlocker uid=501\n",
            "# BEGIN PomodoroBlocker uid=0501\n# END PomodoroBlocker uid=0501\n",
            "# BEGIN PomodoroBlocker (removed when focus ends; delete these lines to unblock now)\n",
            "# END PomodoroBlocker\n",
            "# BEGIN PomodoroBlocker\n# END PomodoroBlocker\n",
            "# BEGIN PomodoroBlocker uid=501\n# BEGIN PomodoroBlocker uid=502\n# END PomodoroBlocker uid=502\n# END PomodoroBlocker uid=501\n",
            "# BEGIN PomodoroBlocker uid=501\n# END PomodoroBlocker\n",
        ]
        for content in malformed {
            XCTAssertThrowsError(try HostsFile.updated(content, hostNames: [], uid: uid)) { error in
                XCTAssertEqual(error as? HostsFileError, .malformedMarkers)
            }
        }
    }

    func testAppendToFileWithoutFinalNewlineKeepsEntrySeparate() throws {
        let updated = try HostsFile.updated("127.0.0.1 localhost", hostNames: ["example.com"], uid: uid)
        XCTAssertTrue(updated.hasPrefix("127.0.0.1 localhost\n# BEGIN PomodoroBlocker uid=501\n"))
    }
}
