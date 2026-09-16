#if canImport(AppKit)
  import Autocomplete
  import CodevisorCore
  import SwiftUI

  /// Open Quickly for the workspace. Typing searches filenames on the machine
  /// that owns the files; an empty query offers recent files and the root
  /// folder. Choosing a folder narrows the search to its contents rather
  /// than opening it, so the whole tree stays one keystroke away.
  struct MacFileOpenPicker: View {
    let model: FilePaneModel
    let focus: Autocomplete.InputFocus
    /// Present when the picker floats over a document: Escape closes it and
    /// opening a file dismisses it.
    var onDismiss: (() -> Void)? = nil

    @Environment(\.openFileDocument) private var openFile
    @State private var query = ""
    @State private var search = FileExplorerSearch()
    /// The last completed search stays on screen while the next one runs,
    /// narrowed locally by the new query, so results never blink away.
    @State private var results: [ServerFileEntry] = []

    private static let style: Autocomplete.Style = {
      var metrics = Autocomplete.Metrics.xcodeMenu
      metrics.maximumWidth = 560
      metrics.maximumHeight = 480
      // Open in New Tab stays on the context menu and ⌘↩; no hover button.
      return Autocomplete.Style(metrics: metrics, showsAccessories: false)
    }()

    private var explorer: FileExplorerModel { model.explorer }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var recentPaths: [String] { model.recents.paths(machineId: model.machineId, root: model.rootPath) }
    private var rootEntries: [ServerFileEntry] { explorer.listings[explorer.root] ?? [] }

    private var loadingState: Autocomplete.LoadingState {
      if trimmedQuery.isEmpty {
        if explorer.loading.contains(explorer.root) { return .loading("Loading files…") }
        if let error = explorer.errors[explorer.root] { return .failure(error) }
        return .ready
      }
      if search.isSearching || search.query != trimmedQuery { return .loading("Searching files…") }
      if let error = search.error { return .failure(error) }
      return .ready
    }

    var body: some View {
      Autocomplete.Suggestions(query: $query, focus: focus, onCancel: onDismiss) {
        if trimmedQuery.isEmpty {
          if !recentPaths.isEmpty {
            Autocomplete.Section("Recent") {
              for path in recentPaths { fileAction(path) }
            }
          }
          Autocomplete.Section(explorer.rootName, id: "root") {
            for entry in rootEntries {
              if entry.isDirectory { folderAction(entry) } else { fileAction(entry.path) }
            }
          }
        } else {
          for entry in results { fileAction(entry.path) }
        }
      }
      .autocompleteStyle(Self.style)
      .autocompleteSearchPrompt("Search files")
      .autocompleteSearchLabel("Search workspace files")
      .autocompleteEmptyMessage("No Matching Files", noItems: "No Files")
      .autocompleteLoadingState(loadingState)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Open File")
      .task { await explorer.load(explorer.root) }
      .task(id: trimmedQuery) {
        await search.update(query: trimmedQuery) { query in
          try await explorer.searchFiles(in: explorer.root, query: query)
        }
        if let result = search.result { results = result.entries }
      }
      .onChange(of: trimmedQuery) { _, query in
        if query.isEmpty { results = [] }
      }
    }

    /// The title mirrors the label ("name  folder") so the popup is measured
    /// for what it draws; the relative path rides along as a search term,
    /// matching the machine's search so local narrowing and results agree.
    private func fileAction(_ path: String) -> Autocomplete.Action {
      let relative = explorer.relativePath(path)
      let name = (relative as NSString).lastPathComponent
      let directory = (relative as NSString).deletingLastPathComponent
      let title = directory.isEmpty ? name : name + "  " + directory
      return Autocomplete.Action(title, id: path, action: { open(path) }) {
        FileIcon(path: path, size: 16)
      } label: {
        HStack(spacing: 6) {
          Text(name).lineLimit(1)
          if !directory.isEmpty {
            Text(directory).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
          }
        }
      }
      .searchTerms([relative])
      .help(path)
      .secondaryActions([
        Autocomplete.SecondaryAction(
          "Open in New Tab", systemImage: "plus.rectangle.on.rectangle",
          shortcut: KeyboardShortcut(.return, modifiers: .command)
        ) { openInNewTab(path) }
      ])
    }

    private func folderAction(_ entry: ServerFileEntry) -> Autocomplete.Action {
      Autocomplete.Action(entry.name, id: entry.path, action: { query = explorer.relativePath(entry.path) + "/" }) {
        FileIcon(path: entry.path, isDirectory: true, size: 16)
      } label: {
        Text(entry.name).lineLimit(1)
      }
      .help("Search in \(entry.name)")
    }

    private func open(_ path: String) {
      model.navigate(to: path)
      onDismiss?()
    }

    private func openInNewTab(_ path: String) {
      guard openFile?(path) == true else { return open(path) }
      onDismiss?()
    }
  }

  /// An empty file pane: the picker centered on the pane background, the
  /// same presentation as the New Tab page it was chosen from.
  struct MacFileOpenPage: View {
    let model: FilePaneModel
    @Environment(\.theme) private var theme
    @State private var focus = Autocomplete.InputFocus()

    private static let cornerRadius: CGFloat = 18

    var body: some View {
      GeometryReader { geometry in
        ScrollView {
          MacFileOpenPicker(model: model, focus: focus)
            .composerGlassSurface(cornerRadius: Self.cornerRadius)
            .padding(20)
            .frame(maxWidth: .infinity)
            .frame(minHeight: geometry.size.height)
        }
      }
      .background(theme.paneBackground)
      .onChange(of: model.explorerFocusRequests) { _, _ in focus.focus() }
    }
  }

  /// The picker anchored to the document title, for switching files without
  /// leaving the pane.
  struct MacFileOpenPopover: View {
    let model: FilePaneModel
    @State private var focus = Autocomplete.InputFocus()

    var body: some View {
      MacFileOpenPicker(model: model, focus: focus, onDismiss: { model.showsExplorer = false })
        .padding(4)
        .onAppear { focus.focus() }
    }
  }
#endif
