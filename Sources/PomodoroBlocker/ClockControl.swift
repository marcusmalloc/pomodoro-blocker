import AppKit
import SwiftUI

/// AppKit handles double clicks, wheel gestures and modifier changes without app-wide monitors.
struct ClockControl: NSViewRepresentable {
    let seconds: TimeInterval
    let minutes: Int
    let isRunning: Bool
    let onBreak: Bool
    let toggle: () -> Void
    let reset: () -> Void
    let setMinutes: (Int) -> Void
    let adjustMinutes: (Int) -> Void

    func makeNSView(context: Context) -> ClockView { ClockView() }

    func updateNSView(_ view: ClockView, context: Context) {
        view.configure(
            seconds: seconds, minutes: minutes, isRunning: isRunning, onBreak: onBreak,
            toggle: toggle, reset: reset, setMinutes: setMinutes, adjustMinutes: adjustMinutes
        )
    }
}

@MainActor
final class ClockView: NSView, NSTextFieldDelegate {
    private let timeLabel = NSTextField(labelWithString: "")
    private let editor = NSTextField(string: "")
    private var seconds: TimeInterval = 0
    private var minutes = 25
    private var isRunning = false
    private var onBreak = false
    private var isEditing = false
    private var optionIsDown = false
    private var firstClickCanEdit = false
    private var wheelRemainder: CGFloat = 0
    private var pendingClick: Task<Void, Never>?
    private var toggle: () -> Void = {}
    private var reset: () -> Void = {}
    private var setMinutes: (Int) -> Void = { _ in }
    private var adjustMinutes: (Int) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let durationCell = ClockDurationCell(textCell: "")
        durationCell.handleKey = { [weak self] event in self?.handleEditorKey(event) ?? false }
        editor.cell = durationCell
        editor.isEditable = true
        editor.isSelectable = true
        for field in [timeLabel, editor] {
            field.font = .monospacedDigitSystemFont(ofSize: 42, weight: .light)
            field.textColor = .labelColor
            field.alignment = .center
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.maximumNumberOfLines = 1
            field.usesSingleLineMode = true
            addSubview(field)
        }
        timeLabel.setAccessibilityElement(false)
        editor.isHidden = true
        editor.delegate = self
        editor.setAccessibilityLabel("Duration in minutes")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Edit minutes", target: self, selector: #selector(accessibilityEdit)),
            NSAccessibilityCustomAction(name: "Reset", target: self, selector: #selector(accessibilityReset))
        ])
    }

    required init?(coder: NSCoder) { nil }

    deinit { pendingClick?.cancel() }

    func configure(
        seconds: TimeInterval, minutes: Int, isRunning: Bool, onBreak: Bool,
        toggle: @escaping () -> Void, reset: @escaping () -> Void,
        setMinutes: @escaping (Int) -> Void, adjustMinutes: @escaping (Int) -> Void
    ) {
        if self.onBreak != onBreak {
            // Input begun in the previous phase must not start or edit the newly selected one.
            cancelPendingClick()
            finishEditing(commit: false)
            firstClickCanEdit = false
            wheelRemainder = 0
        }
        self.seconds = seconds
        self.minutes = minutes
        self.isRunning = isRunning
        self.onBreak = onBreak
        self.toggle = toggle
        self.reset = reset
        self.setMinutes = setMinutes
        self.adjustMinutes = adjustMinutes
        if isRunning, isEditing { finishEditing(commit: false) }
        updateLabel()
    }

    override func layout() {
        super.layout()
        // Use the native cell's font metrics rather than a fixed baseline, including during editing.
        for field in [timeLabel, editor] {
            let height = field.cell?.cellSize.height ?? 52
            field.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            optionIsDown = NSEvent.modifierFlags.contains(.option)
            window.makeFirstResponder(self)
            updateLabel()
        } else {
            cancelPendingClick()
            finishEditing(commit: true, focusClock: false)
        }
    }

    /// The panel calls this each time it opens, including when its content has already been mounted.
    static func focus(in root: NSView) {
        if let clock = root as? ClockView {
            clock.window?.makeFirstResponder(clock)
            clock.optionIsDown = NSEvent.modifierFlags.contains(.option)
            clock.updateLabel()
            return
        }
        for child in root.subviews { focus(in: child) }
    }

    /// Dismissal cancels a pending single click and commits an editor without reclaiming focus.
    static func deactivate(in root: NSView) {
        if let clock = root as? ClockView {
            clock.cancelPendingClick()
            clock.finishEditing(commit: true, focusClock: false)
            clock.optionIsDown = false
            clock.updateLabel()
            return
        }
        for child in root.subviews { deactivate(in: child) }
    }

    override func resignFirstResponder() -> Bool {
        cancelPendingClick()
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return isEditing ? super.hitTest(point) : self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) {
            performReset()
        } else if event.clickCount >= 2 {
            cancelPendingClick()
            if firstClickCanEdit { beginEditing() }
        } else if isRunning {
            // A running clock cannot be edited, so pausing does not wait for a double click.
            firstClickCanEdit = false
            performToggle()
        } else {
            firstClickCanEdit = true
            cancelPendingClick()
            let interval = NSEvent.doubleClickInterval
            pendingClick = Task { [weak self] in
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.pendingClick = nil
                self.performToggle()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        // AppKit can route commands back to this responder after accessibility focus changes.
        // Keep the active draft's semantics even when its native field editor is bypassed.
        if isEditing, handleEditorKey(event) { return }
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36, 76, 49: // Return, keypad Enter, Space
            event.modifierFlags.contains(.option) ? performReset() : performToggle()
        case 126: adjust(by: 1)
        case 125: adjust(by: -1)
        case 53: window?.cancelOperation(nil)
        default:
            if !isRunning, let character = event.charactersIgnoringModifiers,
               character.count == 1, character.allSatisfy({ "0"..."9" ~= $0 }) {
                beginEditing(replacingWith: character)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if isEditing {
            finishEditing(commit: false)
        } else {
            window?.cancelOperation(sender)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        optionIsDown = event.modifierFlags.contains(.option)
        updateLabel()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isRunning, event.scrollingDeltaY != 0, event.momentumPhase.isEmpty else { return }
        if event.hasPreciseScrollingDeltas {
            if event.phase == .began { wheelRemainder = 0 }
            wheelRemainder += event.scrollingDeltaY
            let steps = Int(wheelRemainder / 20)
            if steps != 0 {
                wheelRemainder -= CGFloat(steps * 20)
                adjust(by: steps)
            }
        } else {
            adjust(by: event.scrollingDeltaY > 0 ? 1 : -1)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        performToggle()
        return true
    }

    @objc private func accessibilityEdit() -> Bool {
        guard !isRunning else { return false }
        beginEditing()
        return true
    }

    @objc private func accessibilityReset() -> Bool {
        performReset()
        return true
    }

    func controlTextDidChange(_ notification: Notification) {
        let digits = String(editor.stringValue.filter { "0"..."9" ~= $0 }.prefix(3))
        if digits != editor.stringValue { editor.stringValue = digits }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if isEditing { finishEditing(commit: true, focusClock: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            finishEditing(commit: true)
            performToggle()
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false)
        case #selector(NSResponder.moveUp(_:)):
            adjust(by: 1)
        case #selector(NSResponder.moveDown(_:)):
            adjust(by: -1)
        default: return false
        }
        return true
    }

    private func handleEditorKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command) else { return false }
        switch event.keyCode {
        case 36, 76, 49:
            if event.modifierFlags.contains(.option) {
                performReset()
            } else {
                finishEditing(commit: true)
                performToggle()
            }
        case 126: adjust(by: 1)
        case 125: adjust(by: -1)
        case 53: finishEditing(commit: false)
        default: return false
        }
        return true
    }

    private func beginEditing(replacingWith value: String? = nil) {
        guard !isRunning else { return }
        cancelPendingClick()
        isEditing = true
        setAccessibilityElement(false)
        timeLabel.isHidden = true
        editor.isHidden = false
        editor.stringValue = value ?? String(minutes)
        window?.makeFirstResponder(editor)
        if let value, let textView = editor.currentEditor() as? NSTextView {
            // Native text fields select their whole value on focus; a typed first digit instead
            // needs an insertion point after it so subsequent digits append normally.
            textView.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
        } else {
            editor.currentEditor()?.selectAll(nil)
        }
    }

    private func finishEditing(commit: Bool, focusClock: Bool = true) {
        guard isEditing else { return }
        let value = Int(editor.stringValue)
        isEditing = false
        editor.isHidden = true
        timeLabel.isHidden = false
        setAccessibilityElement(true)
        if commit, let value { setMinutes(value) }
        if focusClock { window?.makeFirstResponder(self) }
        updateLabel()
    }

    private func adjust(by amount: Int) {
        guard !isRunning else { return }
        cancelPendingClick()
        if isEditing {
            let value = min(999, max(1, (Int(editor.stringValue) ?? minutes) + amount))
            editor.stringValue = String(value)
            editor.currentEditor()?.selectAll(nil)
        } else {
            adjustMinutes(amount)
        }
    }

    private func performToggle() {
        cancelPendingClick()
        toggle()
    }

    private func performReset() {
        cancelPendingClick()
        finishEditing(commit: false)
        reset()
    }

    private func cancelPendingClick() {
        pendingClick?.cancel()
        pendingClick = nil
    }

    private func updateLabel() {
        timeLabel.stringValue = optionIsDown ? "Reset" : Self.format(seconds)
        timeLabel.font = optionIsDown
            ? .systemFont(ofSize: 32, weight: .regular)
            : .monospacedDigitSystemFont(ofSize: 42, weight: .light)
        let phase = onBreak ? "Break" : "Focus"
        setAccessibilityLabel("\(phase) timer")
        setAccessibilityValue(Self.format(seconds))
        toolTip = "Click or press Return / Space to \(isRunning ? "pause" : "start"). Double-click or type to edit minutes; ↑ / ↓ and scroll adjust. Hold ⌥ to reset."
        setAccessibilityHelp(toolTip)
        needsLayout = true
    }

    /// Round up between ticks and clamp after sleep so the countdown never displays a negative value.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A cell-scoped editor preserves the standard text field while keeping clock shortcuts local.
private final class ClockDurationCell: NSTextFieldCell {
    var handleKey: ((NSEvent) -> Bool)?
    private lazy var durationEditor: ClockDurationEditor = {
        let editor = ClockDurationEditor()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.handleKey = { [weak self] event in self?.handleKey?(event) ?? false }
        return editor
    }()

    override func fieldEditor(for controlView: NSView) -> NSTextView? { durationEditor }
}

private final class ClockDurationEditor: NSTextView {
    var handleKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}
