import AppKit

@main
enum PomodoroBlockerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let timer: PomodoroTimer
    private let menuBar: MenuBarController

    init(timer: PomodoroTimer = PomodoroTimer()) {
        self.timer = timer
        menuBar = MenuBarController(timer: timer)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar.install()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar.showTimer()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer.reset()
    }
}
