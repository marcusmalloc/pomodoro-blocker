import AppKit
import XCTest
@testable import PomodoroBlocker

/// Sends events directly to the native control; no application windows or system events are opened.
@MainActor
final class ClockControlTests: XCTestCase {
    private final class Actions {
        var toggles = 0
        var resets = 0
        var durations: [Int] = []
        var adjustments: [Int] = []
    }

    private func makeClock(running: Bool = false) -> (ClockView, Actions) {
        let actions = Actions()
        let clock = ClockView()
        clock.configure(
            seconds: 1_500, minutes: 25, isRunning: running, onBreak: false,
            toggle: { actions.toggles += 1 },
            reset: { actions.resets += 1 },
            setMinutes: { actions.durations.append($0) },
            adjustMinutes: { actions.adjustments.append($0) }
        )
        return (clock, actions)
    }

    private func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        )!
    }

    private func click(count: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: count, clickCount: count, pressure: 1
        )!
    }

    private func editor(in clock: ClockView) throws -> NSTextField {
        try XCTUnwrap(clock.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable },
                      "The clock must provide an editable native minute field")
    }

    func testKeyboardAndAccessibilityActivationShareTheClockAction() async {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(36, characters: "\r"))
        clock.keyDown(with: key(49, characters: " "))
        XCTAssertTrue(clock.accessibilityPerformPress())
        XCTAssertEqual(actions.toggles, 3)

        clock.keyDown(with: key(36, characters: "\r", modifiers: .option))
        clock.mouseDown(with: click(modifiers: .option))
        XCTAssertEqual(actions.resets, 2)
        XCTAssertTrue(actions.durations.isEmpty)
    }

    func testStoppedArrowsAdjustOneMinuteAndRunningClockCannotEdit() async throws {
        let (stopped, stoppedActions) = makeClock()
        stopped.keyDown(with: key(126))
        stopped.keyDown(with: key(125))
        XCTAssertEqual(stoppedActions.adjustments, [1, -1])

        let (running, runningActions) = makeClock(running: true)
        running.keyDown(with: key(126))
        running.keyDown(with: key(18, characters: "1"))
        XCTAssertTrue(runningActions.adjustments.isEmpty)
        XCTAssertTrue(try editor(in: running).isHidden)
        running.mouseDown(with: click())
        XCTAssertEqual(runningActions.toggles, 1)
    }

    func testTypingEditsMinutesAndReturnCommitsBeforeStarting() async throws {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        XCTAssertFalse(field.isHidden)
        XCTAssertEqual(field.stringValue, "3")
        field.stringValue = "30"
        XCTAssertTrue(clock.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(actions.durations, [30])
        XCTAssertEqual(actions.toggles, 1)
    }

    func testEscapeDiscardsTheDraftWithoutStarting() async throws {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        field.stringValue = "30"
        XCTAssertTrue(clock.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(field.isHidden)
        XCTAssertTrue(actions.durations.isEmpty)
        XCTAssertEqual(actions.toggles, 0)
    }

    func testClockResponderEscapeCancelsAnActiveDraftInsteadOfCommitting() async throws {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        field.stringValue = "999"
        clock.keyDown(with: key(53))
        XCTAssertTrue(field.isHidden)
        XCTAssertTrue(actions.durations.isEmpty)
        XCTAssertEqual(actions.toggles, 0)

        clock.keyDown(with: key(20, characters: "3"))
        field.stringValue = "30"
        clock.cancelOperation(nil)
        XCTAssertTrue(field.isHidden)
        XCTAssertTrue(actions.durations.isEmpty)
    }

    func testClockResponderReturnCommitsAnActiveDraftBeforeStarting() async throws {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        field.stringValue = "30"
        clock.keyDown(with: key(36, characters: "\r"))
        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(actions.durations, [30])
        XCTAssertEqual(actions.toggles, 1)

        clock.keyDown(with: key(20, characters: "3"))
        field.stringValue = "35"
        clock.keyDown(with: key(49, characters: " ", modifiers: .option))
        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(actions.resets, 1)
        XCTAssertEqual(actions.durations, [30])
        XCTAssertEqual(actions.toggles, 1)
    }

    func testNativeMinuteEditorSpaceCommitsAndOptionReturnResets() async throws {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        let nativeEditor = try XCTUnwrap(field.cell?.fieldEditor(for: field))
        field.stringValue = "30"
        nativeEditor.keyDown(with: key(49, characters: " "))
        XCTAssertEqual(actions.durations, [30])
        XCTAssertEqual(actions.toggles, 1)
        XCTAssertTrue(field.isHidden)

        clock.keyDown(with: key(20, characters: "3"))
        field.stringValue = "35"
        nativeEditor.keyDown(with: key(36, characters: "\r", modifiers: .option))
        XCTAssertEqual(actions.resets, 1)
        XCTAssertEqual(actions.durations, [30])
        XCTAssertEqual(actions.toggles, 1)
        XCTAssertTrue(field.isHidden)
    }

    func testNativeMinuteEditorArrowsChangeTheDraftWithinBounds() async throws {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        let nativeEditor = try XCTUnwrap(field.cell?.fieldEditor(for: field))
        field.stringValue = "999"
        nativeEditor.keyDown(with: key(126))
        XCTAssertEqual(field.stringValue, "999")
        nativeEditor.keyDown(with: key(125))
        XCTAssertEqual(field.stringValue, "998")
        XCTAssertTrue(actions.adjustments.isEmpty)
        nativeEditor.keyDown(with: key(53))
        XCTAssertTrue(field.isHidden)
        XCTAssertTrue(actions.durations.isEmpty)
    }

    func testDoubleClickEditsWithoutFiringThePendingStart() async throws {
        let (clock, actions) = makeClock()
        clock.mouseDown(with: click())
        clock.mouseDown(with: click(count: 2))
        XCTAssertFalse(try editor(in: clock).isHidden)
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        XCTAssertEqual(actions.toggles, 0)
    }

    func testSingleClickStartsOnceAfterTheDoubleClickWindow() async {
        let (clock, actions) = makeClock()
        clock.mouseDown(with: click())
        XCTAssertEqual(actions.toggles, 0)
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        XCTAssertEqual(actions.toggles, 1)
    }

    func testHidingCancelsThePendingStart() async {
        let (clock, actions) = makeClock()
        clock.mouseDown(with: click())
        ClockView.deactivate(in: clock)
        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        XCTAssertEqual(actions.toggles, 0)
    }

    func testChangingPhaseCancelsThePendingStart() async {
        let (clock, focusActions) = makeClock()
        let breakActions = Actions()
        clock.mouseDown(with: click())
        clock.configure(
            seconds: 300, minutes: 5, isRunning: false, onBreak: true,
            toggle: { breakActions.toggles += 1 },
            reset: { breakActions.resets += 1 },
            setMinutes: { breakActions.durations.append($0) },
            adjustMinutes: { breakActions.adjustments.append($0) }
        )

        try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
        XCTAssertEqual(focusActions.toggles, 0)
        XCTAssertEqual(breakActions.toggles, 0)
    }

    func testChangingPhaseDiscardsThePreviousDraftBeforeReplacingActions() async throws {
        let (clock, focusActions) = makeClock()
        let breakActions = Actions()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        field.stringValue = "35"
        clock.configure(
            seconds: 300, minutes: 5, isRunning: false, onBreak: true,
            toggle: { breakActions.toggles += 1 },
            reset: { breakActions.resets += 1 },
            setMinutes: { breakActions.durations.append($0) },
            adjustMinutes: { breakActions.adjustments.append($0) }
        )

        XCTAssertTrue(field.isHidden)
        XCTAssertTrue(focusActions.durations.isEmpty)
        XCTAssertTrue(breakActions.durations.isEmpty)
        // A delayed native end-editing callback must not save the old draft into either phase.
        clock.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertTrue(focusActions.durations.isEmpty)
        XCTAssertTrue(breakActions.durations.isEmpty)
        clock.keyDown(with: key(36, characters: "\r"))
        XCTAssertEqual(focusActions.toggles, 0)
        XCTAssertEqual(breakActions.toggles, 1)
    }

    func testHidingCommitsAValidDraftWithoutStarting() async throws {
        let (clock, actions) = makeClock()
        clock.keyDown(with: key(20, characters: "3"))
        let field = try editor(in: clock)
        field.stringValue = "30"
        ClockView.deactivate(in: clock)
        XCTAssertTrue(field.isHidden)
        XCTAssertEqual(actions.durations, [30])
        XCTAssertEqual(actions.toggles, 0)
    }

    func testCountdownFormattingRoundsUpAndNeverGoesNegative() async {
        XCTAssertEqual(ClockView.format(59.1), "01:00")
        XCTAssertEqual(ClockView.format(1), "00:01")
        XCTAssertEqual(ClockView.format(-1), "00:00")
        XCTAssertEqual(ClockView.format(999 * 60), "999:00")
    }
}
