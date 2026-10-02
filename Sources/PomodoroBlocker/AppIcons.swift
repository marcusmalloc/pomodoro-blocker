import AppKit

/// Cache Launch Services icons so scrolling a list doesn't repeatedly look up the same app.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    /// The icon of an installed app, or nil if it isn't installed.
    static func icon(forApp bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return icon(forFile: url)
    }

    static func icon(forFile url: URL) -> NSImage {
        if let cached = cache[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[url.path] = image
        return image
    }
}
