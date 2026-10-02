import AppKit

/// An app on this Mac, as its bundle describes it.
struct InstalledApp: Identifiable, Hashable, Sendable {
    /// The bundle identifier, which is how the block list refers to an app.
    let id: String
    let name: String
    let url: URL
    /// What the app declares itself to be, such as public.app-category.games, if anything.
    let category: String?
}

enum InstalledApps {
    /// Apps are looked for in these and one level inside them, which takes in /Applications/Utilities and the like.
    private static var folders: [URL] {
        ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Every app in the usual places, by name.
    static func scan() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        for folder in folders {
            for item in contents(of: folder) {
                if item.pathExtension == "app" {
                    if let app = app(at: item) { found[app.id] = app }
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    for inner in contents(of: item) where inner.pathExtension == "app" {
                        if let app = app(at: inner) { found[app.id] = app }
                    }
                }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apps running now that have a Dock icon, wherever they live, since the folders above miss anything run from
    /// Downloads or a games folder.
    static func running() -> [InstalledApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL.flatMap(app(at:)) }
    }

    static func app(at url: URL) -> InstalledApp? {
        // Launch Services can retain an app's old location after it is removed. Bundle's metadata cache alone
        // does not establish that the app is still present.
        var isDirectory: ObjCBool = false
        guard url.pathExtension == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        return InstalledApp(
            id: id, name: url.deletingPathExtension().lastPathComponent, url: url,
            category: bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
        )
    }

    /// Supplement a directory scan with running apps and listed apps registered elsewhere. This is an inventory
    /// refresh, not a row-rendering operation; callers keep the result until their next refresh.
    @MainActor
    static func resolve(scanned: [InstalledApp] = [], including bundleIDs: Set<String>) -> [String: InstalledApp] {
        var found: [String: InstalledApp] = [:]
        for app in scanned + running() { found[app.id] = app }
        for id in bundleIDs where found[id] == nil {
            if let app = registeredApp(bundleID: id) { found[id] = app }
        }
        return found
    }

    /// A registered location counts only while an app bundle with the requested identifier exists there.
    @MainActor
    static func registeredApp(bundleID: String) -> InstalledApp? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let app = app(at: url), app.id == bundleID else { return nil }
        return app
    }

    /// Whether a declared category is one that gets an app blocked: games, entertainment and social networking.
    static func isBlocked(category: String?) -> Bool {
        guard let category else { return false }
        return category.hasSuffix("games")
            || category == "public.app-category.entertainment"
            || category == "public.app-category.social-networking"
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
    }
}
