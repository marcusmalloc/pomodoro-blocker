import XCTest
@testable import PomodoroBlocker

@MainActor
final class TimerSoundTests: XCTestCase {
    func testPackagedCAFBuzzLoadsAndDecodes() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("TimerSound-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.marcusmalloc.pomodoroblocker.sound-test",
                                   "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/tomato-timer-buzz.caf")
        try FileManager.default.copyItem(at: source, to: resources.appendingPathComponent(source.lastPathComponent))

        let bundle = try XCTUnwrap(Bundle(url: app))
        let sound = try XCTUnwrap(TimerSound.load(from: bundle))
        XCTAssertEqual(sound.duration, 2.7, accuracy: 0.05)
    }

    func testMissingBuzzReturnsNilForFallback() async {
        XCTAssertNil(TimerSound.load(from: Bundle(for: TimerSoundTests.self)))
    }
}
