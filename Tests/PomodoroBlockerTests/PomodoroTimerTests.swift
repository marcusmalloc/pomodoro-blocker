import XCTest
@testable import PomodoroBlocker

@MainActor
final class PomodoroTimerTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 1_000)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "com.marcusmalloc.pomodoroblocker.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        // Keep block-list setup empty. Tests never alter the user's preferences or use a blocker.
        defaults.set(Data("[]".utf8), forKey: "blockList")
        return (defaults, name)
    }

    private func makeTimer(defaults: UserDefaults, clock: Clock? = nil) -> PomodoroTimer {
        let clock = clock ?? Clock()
        return PomodoroTimer(defaults: defaults, blockingEnabled: false, automaticallyTicks: false,
                             now: { clock.date })
    }

    func testLegacyPreferencesNormalizeAndPersist() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(" 30 ", forKey: "focusMinutes")
        defaults.set("", forKey: "breakMinutes")
        let timer = makeTimer(defaults: defaults)

        XCTAssertEqual(timer.focusMinutes, 30)
        XCTAssertEqual(timer.breakMinutes, 5)
        XCTAssertEqual(defaults.integer(forKey: "focusMinutes"), 30)
        XCTAssertEqual(defaults.integer(forKey: "breakMinutes"), 5)
        XCTAssertEqual(timer.currentSeconds, 1_800)
        XCTAssertTrue(timer.isIdle)
        XCTAssertNil(timer.domainProblem)
    }

    func testInvalidAndIntegerPreferencesStayInRange() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("nonsense", forKey: "focusMinutes")
        defaults.set(0, forKey: "breakMinutes")
        var timer = makeTimer(defaults: defaults)
        XCTAssertEqual(timer.focusMinutes, 25)
        XCTAssertEqual(timer.breakMinutes, 1)

        defaults.set(10_000, forKey: "focusMinutes")
        defaults.set("9999", forKey: "breakMinutes")
        timer = makeTimer(defaults: defaults)
        XCTAssertEqual(timer.focusMinutes, 999)
        XCTAssertEqual(timer.breakMinutes, 999)
    }

    func testEditedDurationsSurviveResetAndReload() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let timer = makeTimer(defaults: defaults)
        timer.setDuration(40, onBreak: false)
        timer.setDuration(10, onBreak: true)
        timer.toggle()
        // Quitting resets the countdown before the next launch loads saved durations.
        timer.reset()

        let reloadedDefaults = UserDefaults(suiteName: name)!
        let reopenedTimer = makeTimer(defaults: reloadedDefaults)
        XCTAssertEqual(reopenedTimer.focusMinutes, 40)
        XCTAssertEqual(reopenedTimer.breakMinutes, 10)
        XCTAssertEqual(reopenedTimer.currentSeconds, 2_400)
        XCTAssertTrue(reopenedTimer.isIdle)
    }

    func testDurationEditsClampAndPreserveIdleState() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let timer = makeTimer(defaults: defaults)
        timer.setDuration(-5, onBreak: false)
        timer.adjustDuration(-1, onBreak: false)
        XCTAssertEqual(timer.focusMinutes, 1)
        XCTAssertEqual(timer.currentSeconds, 60)
        XCTAssertTrue(timer.isIdle)
        XCTAssertEqual(timer.fractionRemaining, 1)

        timer.adjustDuration(Int.max, onBreak: false)
        timer.setDuration(1_000, onBreak: true)
        XCTAssertEqual(timer.focusMinutes, 999)
        XCTAssertEqual(timer.breakMinutes, 999)
        XCTAssertEqual(defaults.integer(forKey: "focusMinutes"), 999)
        XCTAssertEqual(defaults.integer(forKey: "breakMinutes"), 999)
    }

    func testSelectingAnIdlePhaseUsesItsSavedDurationAndKeepsEditsSeparate() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let timer = makeTimer(defaults: defaults)
        timer.selectPhase(onBreak: true)
        XCTAssertTrue(timer.onBreak)
        XCTAssertTrue(timer.isIdle)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.currentSeconds, 300)
        XCTAssertEqual(timer.fractionRemaining, 1)

        timer.setDuration(10, onBreak: true)
        timer.selectPhase(onBreak: false)
        XCTAssertEqual(timer.currentSeconds, 1_500)
        XCTAssertEqual(timer.focusMinutes, 25)
        timer.selectPhase(onBreak: true)
        XCTAssertEqual(timer.currentSeconds, 600)
        XCTAssertEqual(defaults.integer(forKey: "breakMinutes"), 10)
    }

    func testSelectingAPhaseKeepsRunningAndStartsAFreshDeadline() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let timer = makeTimer(defaults: defaults, clock: clock)
        timer.toggle()
        clock.date += 122
        timer.refresh()
        XCTAssertEqual(timer.currentSeconds, 1_378)

        timer.selectPhase(onBreak: true)
        XCTAssertTrue(timer.onBreak)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.currentSeconds, 300)
        XCTAssertEqual(timer.fractionRemaining, 1)
        clock.date += 20
        timer.refresh()
        XCTAssertEqual(timer.currentSeconds, 280)
        timer.selectPhase(onBreak: true) // Selecting the current phase must preserve its progress.
        XCTAssertEqual(timer.currentSeconds, 280)

        timer.selectPhase(onBreak: false)
        XCTAssertFalse(timer.onBreak)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.currentSeconds, 1_500)
        clock.date += 1_500
        timer.refresh()
        XCTAssertTrue(timer.onBreak)
        XCTAssertEqual(timer.currentSeconds, 300)
    }

    func testSelectingAPausedPhaseStaysPausedAndResetReturnsToFocus() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let timer = makeTimer(defaults: defaults, clock: clock)
        timer.toggle()
        clock.date += 30
        timer.toggle()
        timer.selectPhase(onBreak: true)
        XCTAssertTrue(timer.onBreak)
        XCTAssertFalse(timer.isIdle)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.currentSeconds, 300)
        clock.date += 100
        timer.refresh()
        XCTAssertEqual(timer.currentSeconds, 300)
        timer.toggle()
        clock.date += 10
        timer.refresh()
        XCTAssertEqual(timer.currentSeconds, 290)
        timer.reset()
        XCTAssertFalse(timer.onBreak)
        XCTAssertTrue(timer.isIdle)
        XCTAssertEqual(timer.currentSeconds, 1_500)
    }

    func testStartPauseResumeResetUsesElapsedTime() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let timer = makeTimer(defaults: defaults, clock: clock)
        timer.setDuration(1, onBreak: false)
        timer.toggle()
        XCTAssertTrue(timer.isRunning)
        XCTAssertFalse(timer.isIdle)
        XCTAssertEqual(timer.currentSeconds, 60)

        clock.date += 15
        timer.toggle()
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.currentSeconds, 45)
        XCTAssertEqual(timer.fractionRemaining, 0.75)
        clock.date += 100
        timer.refresh()
        XCTAssertEqual(timer.currentSeconds, 45)

        timer.toggle()
        clock.date += 5
        timer.refresh()
        XCTAssertEqual(timer.currentSeconds, 40)
        timer.reset()
        XCTAssertFalse(timer.isRunning)
        XCTAssertTrue(timer.isIdle)
        XCTAssertFalse(timer.onBreak)
        XCTAssertEqual(timer.currentSeconds, 60)
        XCTAssertEqual(timer.fractionRemaining, 1)
    }

    func testPausedEditingStartsThatPhaseAtItsNewLength() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let timer = makeTimer(defaults: defaults, clock: clock)
        timer.toggle()
        clock.date += 20
        timer.toggle()
        timer.setDuration(10, onBreak: false)
        XCTAssertEqual(timer.currentSeconds, 600)
        XCTAssertEqual(timer.fractionRemaining, 1)
        XCTAssertFalse(timer.isIdle)
        timer.toggle()
        clock.date += 5
        timer.refresh()
        XCTAssertEqual(timer.currentSeconds, 595)
    }

    func testRunningDurationIsLockedButNextPhaseCanChange() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let timer = makeTimer(defaults: defaults, clock: clock)
        timer.setDuration(1, onBreak: false)
        timer.toggle()
        timer.setDuration(10, onBreak: false)
        timer.adjustDuration(1, onBreak: false)
        timer.setDuration(2, onBreak: true)
        XCTAssertEqual(timer.focusMinutes, 1)
        XCTAssertEqual(timer.breakMinutes, 2)
        XCTAssertEqual(timer.currentSeconds, 60)

        clock.date += 60
        timer.refresh()
        XCTAssertTrue(timer.onBreak)
        XCTAssertEqual(timer.currentSeconds, 120)
        XCTAssertEqual(timer.fractionRemaining, 1)
        timer.setDuration(3, onBreak: false)
        clock.date += 120
        timer.refresh()
        XCTAssertFalse(timer.onBreak)
        XCTAssertEqual(timer.currentSeconds, 180)
    }

    func testPhaseTransitionsCarryElapsedTimeAcrossDelayedTicks() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let clock = Clock()
        let timer = makeTimer(defaults: defaults, clock: clock)
        timer.setDuration(1, onBreak: false)
        timer.setDuration(2, onBreak: true)
        timer.toggle()
        clock.date += 190 // Focus (60), break (120), then ten seconds of the next focus.
        timer.refresh()
        XCTAssertTrue(timer.isRunning)
        XCTAssertFalse(timer.onBreak)
        XCTAssertEqual(timer.currentSeconds, 50)
        XCTAssertEqual(timer.fractionRemaining, 50.0 / 60.0, accuracy: 0.000_001)

        clock.date += 50
        timer.toggle() // Pausing exactly on a boundary starts and pauses the break cleanly.
        XCTAssertTrue(timer.onBreak)
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.currentSeconds, 120)
        timer.reset()
        XCTAssertFalse(timer.onBreak)
    }
}
