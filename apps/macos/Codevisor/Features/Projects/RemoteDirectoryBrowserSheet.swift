import SwiftUI
import CodevisorCore

/// A Finder-style folder picker for remote machines, modeled on
/// NSOpenPanel's choose-folder mode: a sidebar (Home, machine root, recent
/// picks), a multi-column browser with real list selection, a breadcrumb
/// popup for ancestors, ⇧⌘G go-to-folder for power users, and ⇧⌘. for
/// hidden folders. Single click selects and previews children in the next
/// column; Choose acts on the selection.
struct RemoteDirectoryBrowserSheet: View {
    private enum SidebarItem: Hashable {
        case home
        case root
        case recent(String)
    }

    let client: any CodevisorServerClienting
    let machineName: String
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: RemoteDirectoryBrowserModel
    @State private var recentsStore = RemoteBrowserRecentsStore()
    @State private var recents: [String] = []
    @State private var showingGoTo = false
    @State private var goToText = ""
    @FocusState private var focusedColumn: String?
    @FocusState private var goToFieldFocused: Bool

    init(
        client: any CodevisorServerClienting,
        machineName: String,
        onChoose: @escaping (String) -> Void
    ) {
        self.client = client
        self.machineName = machineName
        self.onChoose = onChoose
        _model = State(initialValue: RemoteDirectoryBrowserModel(machineName: machineName) { path, showHidden in
            try await client.listDirectory(path: path, showHidden: showHidden)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            if showingGoTo {
                goToBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                columnBrowser
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .background(hiddenShortcuts)
        .frame(
            minWidth: 640, idealWidth: 760, maxWidth: .infinity,
            minHeight: 400, idealHeight: 450, maxHeight: .infinity
        )
        .task {
            recents = recentsStore.recents(forMachine: machineName)
            await model.loadInitial()
            focusedColumn = model.columns.first?.id
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Choose a folder on \(machineName)")
                .font(.headline)
            Spacer()
            breadcrumbMenu
        }
    }

    /// The open-panel-style path popup: current browse root plus its
    /// ancestors, deepest first.
    private var breadcrumbMenu: some View {
        Menu {
            ForEach(model.breadcrumb, id: \.self) { path in
                Button {
                    browse(to: path)
                } label: {
                    Label(displayName(for: path), systemImage: icon(for: path))
                }
            }
        } label: {
            Label(
                model.breadcrumb.first.map(displayName(for:)) ?? machineName,
                systemImage: model.breadcrumb.first.map(icon(for:)) ?? "folder"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.breadcrumb.isEmpty)
        .help("Current folder")
    }

    private var goToBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                TextField(
                    "Go to folder",
                    text: $goToText,
                    prompt: Text(verbatim: "/home/user/projects")
                )
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .focused($goToFieldFocused)
                .onSubmit { submitGoTo() }
                Button("Go") { submitGoTo() }
                Button {
                    closeGoTo()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide the path field")
            }
            if let error = model.goToError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Favorites") {
                Label("Home", systemImage: "house")
                    .tag(SidebarItem.home)
                Label(machineName, systemImage: "server.rack")
                    .tag(SidebarItem.root)
                    .help("The root of \(machineName)'s filesystem")
            }
            if !recents.isEmpty {
                Section("Recents") {
                    ForEach(recents, id: \.self) { path in
                        Label(displayName(for: path), systemImage: "clock")
                            .tag(SidebarItem.recent(path))
                            .help(path)
                            .contextMenu {
                                Button("Remove from Recents") {
                                    recentsStore.remove(path, forMachine: machineName)
                                    recents = recentsStore.recents(forMachine: machineName)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 168)
    }

    /// Sidebar highlight is derived from the current browse root, so
    /// navigating by breadcrumb or ⌘↑ keeps it honest.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            guard let root = model.columns.first?.listing?.path else { return nil }
            if root == model.homePath { return .home }
            if root == "/" { return .root }
            if recents.contains(root) { return .recent(root) }
            return nil
        } set: { item in
            switch item {
            case .home: browse(to: nil)
            case .root: browse(to: "/")
            case let .recent(path): browse(to: path)
            case nil: break
            }
        }
    }

    // MARK: - Columns

    private var columnBrowser: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(model.columns) { column in
                        browserColumn(column)
                            .id(column.id)
                        Divider()
                    }
                }
            }
            .onKeyPress(.rightArrow) { focusColumnAfterFocused() }
            .onKeyPress(.leftArrow) { focusColumnBeforeFocused() }
            .onChange(of: model.columns.last?.id) { _, last in
                guard let last else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    proxy.scrollTo(last, anchor: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func browserColumn(_ column: RemoteDirectoryBrowserModel.Column) -> some View {
        List(selection: selectionBinding(for: column)) {
            ForEach(column.listing?.entries ?? [], id: \.path) { entry in
                entryRow(entry)
                    .tag(entry.path)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focused($focusedColumn, equals: column.id)
        .frame(width: 224)
        .overlay {
            if column.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let error = column.errorMessage {
                ContentUnavailableView {
                    Label("Can't Open Folder", systemImage: "folder.badge.questionmark")
                        .font(.callout)
                } description: {
                    Text(error)
                        .font(.caption)
                }
            } else if column.listing?.entries.isEmpty == true {
                Text("No subfolders")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func entryRow(_ entry: ServerFsEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
                .imageScale(.medium)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if entry.isGitRepo {
                Text("git")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func selectionBinding(for column: RemoteDirectoryBrowserModel.Column) -> Binding<String?> {
        Binding {
            column.selectedEntryPath
        } set: { entryPath in
            guard let entryPath else { return }
            Task { await model.select(entryPath, inColumn: column.path) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            optionsMenu
            if let chosen = model.chosenPath {
                Text(chosen)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 280, alignment: .leading)
                    .help(chosen)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Choose") { choose() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.chosenPath == nil)
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Show Hidden Folders", isOn: showHiddenBinding)
            Divider()
            Button("Go to Folder…") { openGoTo() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Browsing options")
        .accessibilityLabel("Browsing options")
    }

    /// Always-installed keyboard shortcuts (open-panel idioms) that have no
    /// visible chrome: ⇧⌘. hidden folders, ⇧⌘G go to folder, ⌘↑ enclosing
    /// folder.
    private var hiddenShortcuts: some View {
        Group {
            Button("") { showHiddenBinding.wrappedValue.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("") { openGoTo() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("") {
                Task {
                    await model.prependParent()
                    focusedColumn = model.columns.first?.id
                }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!model.canGoUp)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    private var showHiddenBinding: Binding<Bool> {
        Binding {
            model.showHidden
        } set: { value in
            Task { await model.setShowHidden(value) }
        }
    }

    private func browse(to path: String?) {
        Task {
            await model.open(path)
            focusedColumn = model.columns.first?.id
        }
    }

    private func openGoTo() {
        goToText = model.chosenPath ?? ""
        model.clearGoToError()
        showingGoTo = true
        goToFieldFocused = true
    }

    private func closeGoTo() {
        showingGoTo = false
        model.clearGoToError()
        focusedColumn = model.columns.first?.id
    }

    private func submitGoTo() {
        Task {
            if await model.goToPath(goToText) {
                closeGoTo()
            } else {
                goToFieldFocused = true
            }
        }
    }

    private func choose() {
        guard let path = model.chosenPath else { return }
        recentsStore.record(path, forMachine: machineName)
        onChoose(path)
        dismiss()
    }

    /// Moves focus into the child column of the focused column (→), selecting
    /// its first folder when nothing is selected yet — Finder's behavior.
    private func focusColumnAfterFocused() -> KeyPress.Result {
        guard
            let index = model.columns.firstIndex(where: { $0.id == focusedColumn }),
            model.columns.indices.contains(index + 1)
        else { return .ignored }
        let child = model.columns[index + 1]
        guard let entries = child.listing?.entries, !entries.isEmpty else { return .ignored }
        focusedColumn = child.id
        if child.selectedEntryPath == nil, let first = entries.first {
            Task { await model.select(first.path, inColumn: child.path) }
        }
        return .handled
    }

    private func focusColumnBeforeFocused() -> KeyPress.Result {
        guard
            let index = model.columns.firstIndex(where: { $0.id == focusedColumn }),
            index > 0
        else { return .ignored }
        focusedColumn = model.columns[index - 1].id
        return .handled
    }

    // MARK: - Presentation helpers

    private func displayName(for path: String) -> String {
        if path == "/" { return machineName }
        if path == model.homePath { return "Home" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func icon(for path: String) -> String {
        if path == "/" { return "server.rack" }
        if path == model.homePath { return "house" }
        return "folder"
    }
}
