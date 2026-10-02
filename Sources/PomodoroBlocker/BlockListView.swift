import AppKit
import SwiftUI

/// A searchable table with an inline website editor and installed-app picker. Controls use their natural height.
struct BlockListView: View {
    let list: BlockList

    @State private var mode = Mode.table
    @State private var selection = Set<BlockEntry.ID>()
    @State private var filter = ""
    @State private var sortOrder: [KeyPathComparator<BlockEntry>] = []
    @State private var typed = ""
    @State private var typedNothing = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case filter, website
    }

    private enum Mode {
        case table, addWebsite, addApp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BlockListLayout.spacing) {
            if mode == .addApp {
                AppPicker(list: list, done: { mode = .table })
            } else {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($focusedField, equals: .filter)
                    .accessibilityLabel("Filter blocked apps and domains")
                table
                Group {
                    if mode == .addWebsite { websiteField } else { bar }
                }
            }
        }
        // Rows that filtering hides are no longer selected, so − can't remove what can't be seen.
        .onChange(of: filter) { selection.formIntersection(rows.map(\.id)) }
        .onChange(of: mode) { _, mode in
            if mode == .table {
                Task { await list.refreshInstalledApps() }
            }
        }
        .onChange(of: list.visibleEntries) { selection.formIntersection(rows.map(\.id)) }
    }

    private var rows: [BlockEntry] {
        let shown = filter.isEmpty
            ? list.visibleEntries
            : list.visibleEntries.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        return sortOrder.isEmpty ? shown : shown.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 6) {
                    icon(for: entry).accessibilityHidden(true)
                    Text(entry.name).lineLimit(1).help(entry.name)
                }
            }
            TableColumn("Kind", value: \.kind.label) { entry in
                Text(entry.kind.label).foregroundStyle(.secondary)
            }
            .width(64)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .controlSize(.small)
        .frame(height: BlockListLayout.viewportHeight)
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
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        } else if let url = list.installedAppURL(for: entry.value) {
            Image(nsImage: AppIcons.icon(forFile: url))
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            // An app can disappear between the availability refresh and rendering its row.
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    private var bar: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Website…") {
                    typed = ""
                    typedNothing = false
                    mode = .addWebsite
                }
                Button("App…") { mode = .addApp }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Add a website or an app")
            Button(action: removeSelected) {
                Image(systemName: "minus")
            }
            .disabled(selection.isEmpty)
            .accessibilityLabel("Remove selected blocked apps and domains")
            .help("Remove the selected rows")
            Spacer()
            Button("Restore Defaults") { list.restoreDefaults() }
                .buttonStyle(.borderless)
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
                .onExitCommand { mode = .table }
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
                Button("Cancel") { mode = .table }
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
            mode = .table
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
            HStack(spacing: 8) {
                Text("Block List")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close block list")
                .help("Close")
            }
            .padding(.horizontal, 4)

            BlockListView(list: timer.blockList)

            if let problem = timer.domainProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PanelLayout.inset)
        .frame(width: PanelLayout.blockListWidth)
        .pomodoroSurface()
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The table and app picker share a viewport; controls below them use only the space they need.
enum BlockListLayout {
    static let viewportHeight: CGFloat = 208
    static let spacing: CGFloat = 10
}
