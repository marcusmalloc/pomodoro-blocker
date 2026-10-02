import Foundation
import Observation

/// One thing to block during focus: an app, picked out by its bundle identifier, or a website, by its domain.
struct BlockEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case app, website

        var label: String { self == .app ? "App" : "Website" }
    }

    let kind: Kind
    /// An app's bundle identifier, or a website's domain.
    let value: String
    /// What the list shows: an app's name, or the domain itself.
    let name: String

    var id: String { "\(kind.rawValue):\(value)" }
}

/// The apps and websites blocked during focus, which is what the table in the panel edits. It starts out holding the
/// defaults and from then on changes only when it's edited, so what's removed stays removed. An app that's removed
/// also stays unblocked when its category would otherwise get it blocked, which is what lets Messages be kept.
@MainActor
@Observable
final class BlockList {
    /// In the order shown. Anything added later goes on top, where it's in view.
    private(set) var entries: [BlockEntry] {
        didSet {
            rebuild()
            save()
            onChange?()
        }
    }

    /// Apps taken off the list, or exempted from the start, which are never blocked just for their category.
    private(set) var exempt: Set<String> {
        didSet { save() }
    }

    /// Saved app rules remain active even when their apps are absent. The panel only shows apps present on this Mac.
    var visibleEntries: [BlockEntry] {
        entries.filter { $0.kind == .website || installedApps[$0.value] != nil }
    }

    private var installedApps: [String: InstalledApp] = [:]
    @ObservationIgnored private var inventoryRevision = 0

    /// The websites and apps in `entries`, kept to hand since an app launch asks about them.
    @ObservationIgnored private(set) var domains: [String] = []
    @ObservationIgnored private(set) var appIDs: Set<String> = []

    /// Called after every change to the entries.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let store: UserDefaults

    private enum Keys {
        static let entries = "blockList"
        static let exempt = "exemptApps"
        /// Where the websites were kept before there was a list: a text box with one domain per line.
        static let typedDomains = "blockedDomains"
    }

    enum Decision {
        /// Leave it be.
        case allow
        /// It's on the list.
        case listed
        /// It isn't on the list but its category says to block it.
        case category
    }

    init(defaults: UserDefaults = .standard) {
        store = defaults
        if let data = defaults.data(forKey: Keys.entries),
           let saved = try? JSONDecoder().decode([BlockEntry].self, from: data) {
            entries = saved
            exempt = Set(defaults.stringArray(forKey: Keys.exempt) ?? [])
            rebuild()
        } else {
            // First launch of this version: the domains typed into the old text box stay, on top of the defaults.
            let typed = DomainBlocker.parse(defaults.string(forKey: Keys.typedDomains) ?? "")
            entries = typed.map { BlockEntry(kind: .website, value: $0, name: $0) }
            exempt = []
            rebuild()
            restoreDefaults()
            defaults.removeObject(forKey: Keys.typedDomains)
        }
        installedApps = InstalledApps.resolve(scanned: Array(installedApps.values), including: appIDs)
    }

    /// Refresh when the panel opens or returns from its app picker. Scanning is off the main actor; rendering reads
    /// only the resulting inventory. A later refresh supersedes an older scan that is still in flight.
    func refreshInstalledApps() async {
        inventoryRevision += 1
        let revision = inventoryRevision
        let scanned = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
        guard !Task.isCancelled, revision == inventoryRevision else { return }
        let refreshed = InstalledApps.resolve(scanned: scanned, including: appIDs)
        if refreshed != installedApps { installedApps = refreshed }
    }

    /// Icons share the inventory's validated locations instead of looking up each row in Launch Services.
    func installedAppURL(for bundleID: String) -> URL? {
        installedApps[bundleID]?.url
    }

    /// What to do about an app that's running or launching.
    func decision(bundleID: String, category: String?) -> Decision {
        guard !Self.isProtected(bundleID) else { return .allow }
        if appIDs.contains(bundleID) { return .listed }
        if !exempt.contains(bundleID), InstalledApps.isBlocked(category: category) { return .category }
        return .allow
    }

    /// Apps that can't be quit without breaking the session, and this one, which would be quitting itself.
    nonisolated static func isProtected(_ bundleID: String) -> Bool {
        bundleID == Bundle.main.bundleIdentifier
            || ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver"]
                .contains(bundleID)
    }

    /// Adds the websites that `text` names, new ones first, and says whether it named any at all.
    @discardableResult
    func addWebsites(from text: String) -> Bool {
        let named = DomainBlocker.parse(text)
        let known = Set(entries.map(\.id))
        let new = named.map { BlockEntry(kind: .website, value: $0, name: $0) }.filter { !known.contains($0.id) }
        if !new.isEmpty { entries.insert(contentsOf: new, at: 0) }
        return !named.isEmpty
    }

    func add(_ app: InstalledApp) {
        installedApps[app.id] = app
        add(bundleID: app.id, name: app.name)
    }

    /// Adds an app if it's allowed to be blocked, and makes sure it will be.
    func add(bundleID: String, name: String) {
        guard !Self.isProtected(bundleID) else { return }
        if installedApps[bundleID] == nil, let app = InstalledApps.registeredApp(bundleID: bundleID) {
            installedApps[bundleID] = app
        }
        exempt.remove(bundleID)
        let entry = BlockEntry(kind: .app, value: bundleID, name: name)
        if !entries.contains(entry) { entries.insert(entry, at: 0) }
    }

    func remove(_ ids: Set<BlockEntry.ID>) {
        let removed = entries.filter { ids.contains($0.id) }
        exempt.formUnion(removed.filter { $0.kind == .app }.map(\.value))
        entries.removeAll { ids.contains($0.id) }
    }

    /// Puts back whatever default has been removed, and lets the apps among them be blocked again. Everything else on
    /// the list stays. Apps installed here that are blocked for their category are added too, so the list shows them
    /// instead of hiding them behind a rule.
    func restoreDefaults() {
        exempt = DefaultBlocks.exemptApps
        var known = Set(entries.map(\.id))
        var apps: [BlockEntry] = []
        var sites: [BlockEntry] = []
        func offer(_ entry: BlockEntry, into list: inout [BlockEntry]) {
            if known.insert(entry.id).inserted { list.append(entry) }
        }
        let scanned = InstalledApps.scan()
        installedApps = InstalledApps.resolve(scanned: scanned, including: appIDs.union(DefaultBlocks.apps.map(\.id)))
        for app in scanned where InstalledApps.isBlocked(category: app.category)
            && !exempt.contains(app.id) && !Self.isProtected(app.id) {
            offer(BlockEntry(kind: .app, value: app.id, name: app.name), into: &apps)
        }
        for app in DefaultBlocks.apps {
            offer(BlockEntry(kind: .app, value: app.id, name: app.name), into: &apps)
        }
        for domain in DefaultBlocks.websites {
            offer(BlockEntry(kind: .website, value: domain, name: domain), into: &sites)
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !apps.isEmpty || !sites.isEmpty { entries += apps + sites }
    }

    private func rebuild() {
        domains = entries.filter { $0.kind == .website }.map(\.value)
        appIDs = Set(entries.filter { $0.kind == .app }.map(\.value))
    }

    private func save() {
        store.set(try? JSONEncoder().encode(entries), forKey: Keys.entries)
        store.set(exempt.sorted(), forKey: Keys.exempt)
    }
}
