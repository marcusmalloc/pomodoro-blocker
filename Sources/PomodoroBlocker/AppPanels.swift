import AppKit
import SwiftUI

/// A transparent host lets the shared SwiftUI material draw the only background and rounded edge.
@MainActor
private final class FrostedPanel: NSPanel {
    var onCancel: (() -> Void)?
    private let transient: Bool

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !transient }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    init(title: String, transient: Bool) {
        self.transient = transient
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        self.title = title
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = transient ? .popUpMenu : .normal
        collectionBehavior = transient
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            : [.fullScreenAuxiliary, .moveToActiveSpace]
        isMovableByWindowBackground = !transient
        hidesOnDeactivate = false
    }
}

@MainActor
final class TimerPanelController: NSObject, NSWindowDelegate {
    private let panel = FrostedPanel(title: "Pomodoro", transient: true)
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private weak var statusButton: NSStatusBarButton?

    var isVisible: Bool { panel.isVisible }

    init(timer: PomodoroTimer) {
        super.init()
        let content = FittingHostingView(rootView: TimerPanel(timer: timer))
        content.sizingOptions = [.intrinsicContentSize]
        panel.contentView = content
        content.onSizeChange = { [weak self] in self?.resizeIfVisible() }
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }
    }

    func show(below button: NSStatusBarButton) {
        statusButton = button
        resizeToFit()
        position(below: button)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let content = panel.contentView { ClockView.focus(in: content) }
        monitorOutsideClicks()
    }

    func hide() {
        if let content = panel.contentView { ClockView.deactivate(in: content) }
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        removeClickMonitors()
    }

    func resizeIfVisible() {
        guard isVisible else { return }
        if resizeToFit(), let statusButton { position(below: statusButton) }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Let AppKit finish restoring focus after menu tracking or app activation.
        Task { @MainActor [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            self.hide()
        }
    }

    @discardableResult
    private func resizeToFit() -> Bool {
        guard let content = panel.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        let height = content.intrinsicContentSize.height
        guard height.isFinite, height > 0 else { return false }
        let size = NSSize(width: PanelLayout.timerWidth, height: height)
        guard size != panel.contentLayoutRect.size else { return false }
        panel.setContentSize(size)
        return true
    }

    private func position(below button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? anchor
        let inset: CGFloat = 8
        let x = min(max(anchor.midX - panel.frame.width / 2, area.minX + inset), area.maxX - panel.frame.width - inset)
        let y = max(area.minY + inset, min(anchor.minY - panel.frame.height - 6, area.maxY - panel.frame.height - inset))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func monitorOutsideClicks() {
        removeClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.statusButton?.window {
                    self.hide()
                }
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }
}

/// This window persists independently of the timer panel; its table is never animated through a collapse.
@MainActor
final class BlockListPanelController {
    private let timer: PomodoroTimer
    private let panel = FrostedPanel(title: "Block List", transient: false)
    private var hasPosition = false

    init(timer: PomodoroTimer) {
        self.timer = timer
        let content = FittingHostingView(rootView: BlockListPanel(timer: timer, onClose: { [weak self] in self?.hide() }))
        content.sizingOptions = [.intrinsicContentSize]
        panel.contentView = content
        content.onSizeChange = { [weak self] in self?.resizeToFit() }
        panel.onCancel = { [weak self] in self?.hide() }
    }

    func show() {
        resizeToFit()
        if !hasPosition {
            panel.center()
            hasPosition = true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        Task { await timer.blockList.refreshInstalledApps() }
    }

    private func resizeToFit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.intrinsicContentSize.height
        guard height.isFinite, height > 0 else { return }
        let size = NSSize(width: PanelLayout.blockListWidth, height: height)
        guard size != panel.contentLayoutRect.size else { return }
        let top = panel.frame.maxY
        panel.setContentSize(size)
        if hasPosition { panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height)) }
    }

    private func hide() {
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
    }
}

/// SwiftUI editor modes change intrinsic height. Coalesce layout invalidations and resize the
/// native host after that update, preserving its top edge rather than animating a native table.
@MainActor
private final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?
    private var sizeUpdateQueued = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !sizeUpdateQueued else { return }
        sizeUpdateQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sizeUpdateQueued = false
            self.onSizeChange?()
        }
    }
}
