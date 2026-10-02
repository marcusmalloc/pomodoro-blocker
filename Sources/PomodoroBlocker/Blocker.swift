import AppKit
import SwiftUI

/// Keeps the apps on the block list closed while a focus phase runs, and shows a rotten tomato when one is opened
/// anyway. So are games, entertainment and social apps that aren't on it yet (judged by the category they declare,
/// e.g. Discord is social networking), which then join the list. The listed websites are blocked in every browser
/// and app for the same time.
@MainActor
final class Blocker {
    let list: BlockList
    let domains = DomainBlocker()

    /// On while a focus phase is running. Turning it on quits any blocked apps that are open. They're quit
    /// rather than hidden because switching to a hidden app puts its windows on screen for a few frames
    /// before anything can react, whereas a launch can be stopped before the app draws anything.
    var isActive = false {
        didSet {
            domains.isActive = isActive
            guard isActive, !oldValue else { return }
            for app in NSWorkspace.shared.runningApplications where shouldBlock(app) {
                app.terminate()
            }
        }
    }

    private let splash = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    private var splashDismissal: Task<Void, Never>?

    init(list: BlockList) {
        self.list = list
        list.onChange = { [weak self] in self?.listChanged() }
        domains.domains = list.domains

        splash.isOpaque = false
        splash.backgroundColor = .clear
        splash.hasShadow = true
        splash.level = .floating
        splash.ignoresMouseEvents = true
        splash.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // willLaunch arrives before a newly opened app has drawn anything, so it's killed outright; it has nothing
        // to lose yet. didActivate catches one still running because it didn't quit when focus started (it may
        // have asked to save first), so that one is asked to quit again instead.
        let workspace = NSWorkspace.shared.notificationCenter
        let events = [
            (NSWorkspace.willLaunchApplicationNotification, true),
            (NSWorkspace.didActivateApplicationNotification, false),
        ]
        for (name, force) in events {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                MainActor.assumeIsolated { self?.block(app, force: force) }
            }
        }
    }

    private func block(_ app: NSRunningApplication, force: Bool) {
        guard isActive, shouldBlock(app) else { return }
        if force { app.forceTerminate() } else { app.terminate() }
        showSplash(for: app.localizedName ?? "This app")
    }

    /// Whether `app` is to be stopped. One that's only here for its category goes onto the list first, so the list
    /// shows everything that gets blocked and anything unwanted can be taken off it.
    private func shouldBlock(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        let category = app.bundleURL.flatMap { InstalledApps.app(at: $0)?.category }
        switch list.decision(bundleID: id, category: category) {
        case .allow:
            return false
        case .listed:
            return true
        case .category:
            list.add(bundleID: id, name: app.localizedName ?? id)
            return true
        }
    }

    private func listChanged() {
        domains.domains = list.domains
    }

    /// Shows the rotten tomato in the middle of the screen under the pointer, then fades it out.
    private func showSplash(for appName: String) {
        let content = NSHostingView(rootView: BlockedAppSplash(appName: appName))
        splash.contentView = content
        splash.setContentSize(content.fittingSize)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            splash.setFrameOrigin(NSPoint(x: area.midX - splash.frame.width / 2, y: area.midY - splash.frame.height / 2))
        }
        splash.alphaValue = 1
        splash.orderFrontRegardless()

        splashDismissal?.cancel()
        splashDismissal = Task { [splash] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            splash.animator().alphaValue = 0
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            splash.orderOut(nil)
        }
    }
}

struct BlockedAppSplash: View {
    let appName: String

    var body: some View {
        VStack(spacing: 10) {
            Text("🍅")
                .font(.system(size: 88))
                // Dull and brown it: rotten.
                .saturation(0.35)
                .brightness(-0.1)
                .colorMultiply(Color(red: 0.8, green: 0.65, blue: 0.4))
                .rotationEffect(.degrees(-12))
            Text("\(appName) is blocked")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: PanelLayout.timerWidth)
        .pomodoroSurface()
    }
}
