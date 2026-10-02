import AppKit
import SwiftUI

/// A quiet, searchable list with an inline website editor and installed-app picker.
struct BlockListView: View {
    let list: BlockList
    let onClose: () -> Void

    @State private var mode = Mode.list
    @State private var selection = Set<BlockEntry.ID>()
    @State private var filter = ""
    @State private var typed = ""
    @State private var typedNothing = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case filter, website
    }

    private enum Mode {
        case list, addWebsite, addApp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BlockListLayout.spacing) {
            if mode == .addApp {
                AppPicker(list: list, done: { mode = .list }, onClose: onClose)
            } else {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Search", text: $filter)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .filter)
                            .accessibilityLabel("Search blocked apps and domains")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))

                    BlockListCloseButton(action: onClose)
                }
                blockedRows
                Group {
                    if mode == .addWebsite { websiteField } else { bar }
                }
            }
        }
        .font(.system(size: 13))
        // Rows that filtering hides are no longer selected, so − can't remove what can't be seen.
        .onChange(of: filter) { selection.formIntersection(rows.map(\.id)) }
        .onChange(of: mode) { _, mode in
            if mode == .list {
                Task { await list.refreshInstalledApps() }
            }
        }
        .onChange(of: list.visibleEntries) { selection.formIntersection(rows.map(\.id)) }
    }

    private var rows: [BlockEntry] {
        filter.isEmpty
            ? list.visibleEntries
            : list.visibleEntries.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var blockedRows: some View {
        let entries = rows
        return List(entries, selection: $selection) { entry in
            HStack(spacing: 11) {
                icon(for: entry).accessibilityHidden(true)
                Text(entry.name).lineLimit(1).help(entry.name)
                Spacer(minLength: 0)
            }
            .frame(height: BlockListLayout.rowHeight)
            .contentShape(.rect)
            .alignmentGuide(.listRowSeparatorLeading) { _ in -10 }
            .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
            .listRowSeparator(entry.id == entries.last?.id ? .hidden : .visible, edges: .bottom)
            .listRowSeparatorTint(.primary.opacity(0.08))
            .tag(entry.id)
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, BlockListLayout.rowHeight)
        .scrollContentBackground(.hidden)
        .frame(height: BlockListLayout.viewportHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            if rows.isEmpty {
                Text(filter.isEmpty ? "Your block list is empty." : "No matching apps or domains.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .onDeleteCommand(perform: removeSelected)
    }

    @ViewBuilder
    private func icon(for entry: BlockEntry) -> some View {
        if entry.kind == .website {
            Image(systemName: "globe")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: BlockListLayout.iconSize, height: BlockListLayout.iconSize)
        } else if let url = list.installedAppURL(for: entry.value) {
            Image(nsImage: AppIcons.icon(forFile: url))
                .resizable()
                .frame(width: BlockListLayout.iconSize, height: BlockListLayout.iconSize)
        } else {
            // An app can disappear between the availability refresh and rendering its row.
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: BlockListLayout.iconSize, height: BlockListLayout.iconSize)
        }
    }

    private var bar: some View {
        HStack {
            HStack(spacing: 0) {
                Menu {
                    Button("Website…") {
                        typed = ""
                        typedNothing = false
                        mode = .addWebsite
                    }
                    Button("App…") { mode = .addApp }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.secondary)
                .fixedSize()
                .accessibilityLabel("Add a website or an app")
                .help("Add a website or an app")

                Rectangle()
                    .fill(.primary.opacity(0.12))
                    .frame(width: 1, height: 14)

                Button(action: removeSelected) {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(selection.isEmpty)
                .accessibilityLabel("Remove selected blocked apps and domains")
                .help("Remove the selected rows")
            }
            .foregroundStyle(.secondary)
            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

            Spacer()
            Button("Restore Defaults") { list.restoreDefaults() }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help("Adds back any default app or website that was removed")
        }
        .controlSize(.small)
    }

    private var websiteField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Website, such as example.com", text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .website)
                .accessibilityLabel("Website address to block")
                .onSubmit(addTyped)
                .onExitCommand { mode = .list }
                .onAppear { focusedField = .website }
                .onChange(of: typed) { typedNothing = false }
            HStack {
                // Validation shares the button row, so an invalid address doesn't resize the panel.
                if typedNothing {
                    Text("Invalid address.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { mode = .list }
                Button("Add", action: addTyped)
                    .disabled(typed.allSatisfy(\.isWhitespace))
            }
        }
        .controlSize(.small)
    }

    private func addTyped() {
        guard !typed.allSatisfy(\.isWhitespace) else { return }
        if list.addWebsites(from: typed) {
            selection = []
            mode = .list
        } else {
            typedNothing = true
        }
    }

    private func removeSelected() {
        list.remove(selection)
        selection = []
    }
}

/// Content for the separate block-list window; the shell owns its lifetime and position.
struct BlockListPanel: View {
    let timer: PomodoroTimer
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BlockListLayout.spacing) {
            BlockListView(list: timer.blockList, onClose: onClose)

            if let problem = timer.domainProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(BlockListLayout.inset)
        .frame(width: PanelLayout.blockListWidth)
        .pomodoroSurface()
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct BlockListCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close block list")
        .help("Close")
    }
}

/// Seven comfortable rows share a viewport with the installed-app picker.
enum BlockListLayout {
    static let rowHeight: CGFloat = 42
    static let iconSize: CGFloat = 21
    static let viewportHeight: CGFloat = 7 * rowHeight
    static let spacing: CGFloat = 12
    static let inset: CGFloat = 16
}
