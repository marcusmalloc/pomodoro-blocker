import AppKit
import Observation
import ServiceManagement

/// AppKit distinguishes the status item's left and right clicks; the timer owns all countdown state.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let timer: PomodoroTimer
    private var statusItem: NSStatusItem?
    private lazy var timerPanel = TimerPanelController(timer: timer)
    private lazy var blockListPanel = BlockListPanelController(timer: timer)
    private let menu = NSMenu()
    private let loginItem = NSMenuItem(
        title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
    )

    init(timer: PomodoroTimer) {
        self.timer = timer
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Pomodoro timer")
        }
        statusItem = item

        let blockListItem = NSMenuItem(
            title: "Block List…", action: #selector(showBlockList), keyEquivalent: ""
        )
        blockListItem.target = self
        loginItem.target = self
        let quitItem = NSMenuItem(
            title: "Quit Pomodoro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        menu.addItem(blockListItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        menu.delegate = self
        updateStatusItem()
        observeTimer()
    }

    /// Reopening the app from Finder shows the same panel as a left click on its status item.
    func showTimer() {
        guard let button = statusItem?.button else { return }
        timerPanel.show(below: button)
    }

    @objc private func statusItemClicked() {
        guard let event = NSApplication.shared.currentEvent, let button = statusItem?.button else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu(with: event, for: button)
        } else if timerPanel.isVisible {
            timerPanel.hide()
        } else {
            showTimer()
        }
    }

    /// Shared entry point keeps the native menu independent of its status-bar anchor.
    func showContextMenu(with event: NSEvent, for view: NSView) {
        timerPanel.hide()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc func showBlockList() {
        timerPanel.hide()
        blockListPanel.show()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginItem.toolTip = status == .requiresApproval ? "Approval is required in System Settings." : nil
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func updateStatusItem() {
        statusItem?.button?.image = .depletingCircle(timer.fractionRemaining)
        let phase = timer.onBreak ? "Break" : "Focus"
        let state = timer.isRunning ? "running" : (timer.isIdle ? "ready" : "paused")
        statusItem?.button?.toolTip = "\(phase) · \(state)"
        timerPanel.resizeIfVisible()
    }

    /// Observation keeps the icon current without a second polling timer.
    private func observeTimer() {
        withObservationTracking {
            _ = timer.fractionRemaining
            _ = timer.isRunning
            _ = timer.isIdle
            _ = timer.onBreak
            _ = timer.domainProblem
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateStatusItem()
                self?.observeTimer()
            }
        }
    }
}
