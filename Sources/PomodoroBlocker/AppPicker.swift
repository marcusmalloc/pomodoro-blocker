import SwiftUI

/// Apps available to block, with running apps first and a viewport shared with the block-list table.
struct AppPicker: View {
    let list: BlockList
    let done: () -> Void

    @State private var apps: [InstalledApp] = []
    @State private var running = Set<String>()
    @State private var search = ""
    @State private var isLoading = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: BlockListLayout.spacing) {
            HStack {
                TextField("Search apps", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityLabel("Search available apps")
                Button("Cancel", action: done)
            }
            .controlSize(.small)

            List(shown) { app in
                Button {
                    list.add(app)
                    done()
                } label: {
                    HStack(spacing: 6) {
                        Image(nsImage: AppIcons.icon(forFile: app.url))
                            .resizable()
                            .frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Text(app.name).lineLimit(1)
                        Spacer()
                        if running.contains(app.id) {
                            Text("Running")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(app.name) to blocked apps")
                .accessibilityHint(running.contains(app.id) ? "This app is currently running." : "")
                .help("Block \(app.name) during focus")
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .controlSize(.small)
            .frame(height: BlockListLayout.viewportHeight)
            .overlay {
                if isLoading {
                    ProgressView("Finding apps…")
                        .controlSize(.small)
                } else if shown.isEmpty {
                    Text(search.isEmpty ? "No apps available to add." : "No apps match your search.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
        .onExitCommand(perform: done)
        .task {
            await load()
            if !Task.isCancelled { searchFocused = true }
        }
    }

    private var shown: [InstalledApp] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func load() async {
        isLoading = true
        let installed = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
        // The scan can finish after Cancel or the panel closes; don't update the retired picker.
        guard !Task.isCancelled else { return }

        let current = InstalledApps.running()
        running = Set(current.map(\.id))
        var byID: [String: InstalledApp] = [:]
        for app in installed + current { byID[app.id] = byID[app.id] ?? app }
        apps = byID.values
            .filter { !list.appIDs.contains($0.id) && !BlockList.isProtected($0.id) }
            .sorted {
                let (a, b) = (running.contains($0.id), running.contains($1.id))
                return a != b ? a : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        isLoading = false
    }
}
