import AppKit
import SwiftUI

/// A documentation-only stage around production views. Capturing the view, rather than the screen,
/// excludes the pointer, other windows and desktop state. Blocking and preference writes are isolated.
@main
@MainActor
enum ScreenshotRenderer {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "com.marcusmalloc.pomodoroblocker.screenshots.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(25, forKey: "focusMinutes")
        defaults.set(5, forKey: "breakMinutes")
        let entries = ["reddit.com", "youtube.com", "twitch.tv", "instagram.com", "x.com"]
            .map { BlockEntry(kind: .website, value: $0, name: $0) }
        defaults.set(try JSONEncoder().encode(entries), forKey: "blockList")
        let list = BlockList(defaults: defaults)
        // Keep the example relevant to the machine rendering it; never show an absent app.
        for bundleID in ["com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.spotify.client"] {
            if let app = InstalledApps.registeredApp(bundleID: bundleID) { list.add(app) }
        }
        let focus = PomodoroTimer(defaults: defaults, blockList: list,
                                  blockingEnabled: false, automaticallyTicks: false)
        let rest = PomodoroTimer(defaults: defaults, blockingEnabled: false, automaticallyTicks: false)
        rest.selectPhase(onBreak: true)

        let captures: [(String, NSWindow)] = [
            ("focus", stage(TimerPanel(timer: focus), size: NSSize(width: 370, height: 219))),
            ("break", stage(TimerPanel(timer: rest), size: NSSize(width: 370, height: 219))),
            ("block-list", stage(BlockListPanel(timer: focus, onClose: {}), size: NSSize(width: 500, height: 424)))
        ]
        // Give AppKit-backed text fields and tables a normal layout/display cycle before capture.
        app.finishLaunching()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        for (name, window) in captures {
            try capture(window, to: output.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }
    }

    private static func stage<Content: View>(_ content: Content, size: NSSize) -> NSWindow {
        let root = ScreenshotStage(content: content)
            .environment(\.colorScheme, .dark)
            .tint(.blue)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.orderFront(nil)
        return window
    }

    private static func capture(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw CaptureError.missingView }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bounds = view.bounds
        // Explicit 2x output keeps screenshots sharp on either Retina or standard displays.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CaptureError.missingBitmap
        }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.missingPNG
        }
        try png.write(to: url, options: .atomic)
        print("Rendered \(url.path)")
    }

    private enum CaptureError: Error { case missingView, missingBitmap, missingPNG }
}

private struct ScreenshotStage<Content: View>: View {
    let content: Content

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.22, green: 0.19, blue: 0.39),
                                    Color(red: 0.11, green: 0.25, blue: 0.42),
                                    Color(red: 0.06, green: 0.46, blue: 0.49)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            content.shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        }
    }
}
