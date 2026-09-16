#if canImport(UIKit)
  import CodevisorCore
  import SwiftUI

  extension EnvironmentValues {
    @Entry var closeFileBrowser: (() -> Void)?
  }

  /// Open File on iPhone and iPad: folder pages in a navigation stack, with
  /// filename search on the machine that owns the files.
  struct FileBrowserSheet: View {
    let model: FilePaneModel

    var body: some View {
      NavigationStack {
        FileBrowserView(model: model)
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
  }

  /// The browser as an empty pane's content, or inside the sheet above.
  struct FileBrowserView: View {
    let model: FilePaneModel
    @Environment(\.openFileDocument) private var openFile

    var body: some View {
      FileExplorerFolderPage(
        model: model.explorer, directory: model.explorer.root, selectedPath: model.path,
        open: { model.navigate(to: $0) },
        openInTab: { target in
          model.showsExplorer = false
          _ = openFile?(target)
        })
    }
  }

  private struct FileExplorerFolderPage: View {
    @Bindable var model: FileExplorerModel
    let directory: String
    let selectedPath: String
    let open: (String) -> Void
    let openInTab: (String) -> Void
    @State private var filter = ""
    @State private var nextFolder: String?
    @State private var search = FileExplorerSearch()
    @Environment(\.closeFileBrowser) private var closeBrowser

    private var entries: [ServerFileEntry] {
      if !filter.isEmpty { return search.query == filter ? search.result?.entries ?? [] : [] }
      return model.listings[directory] ?? []
    }

    var body: some View {
      List {
        if !filter.isEmpty, let notice = search.notice {
          Text(notice).font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(entries) { entry in
          if entry.isDirectory {
            Button {
              nextFolder = entry.path
            } label: {
              HStack {
                row(entry)
                Image(systemName: "chevron.right")
                  .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
              }
            }
          } else {
            Button {
              open(entry.path)
            } label: {
              row(entry)
            }
            .contextMenu {
              Button("Open in New Tab", systemImage: "plus.rectangle.on.rectangle") { openInTab(entry.path) }
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationDestination(item: $nextFolder) { folder in
        FileExplorerFolderPage(
          model: model, directory: folder, selectedPath: selectedPath,
          open: { path in
            nextFolder = nil
            Task { @MainActor in
              await Task.yield()
              open(path)
            }
          },
          openInTab: { path in
            nextFolder = nil
            Task { @MainActor in
              await Task.yield()
              openInTab(path)
            }
          })
      }
      .contentMargins(.top, 12, for: .scrollContent)
      .overlay {
        if entries.isEmpty {
          if !filter.isEmpty && (search.isSearching || search.query != filter) {
            ProgressView("Searching files…")
          } else if filter.isEmpty && model.loading.contains(directory) {
            ProgressView("Loading files…")
          } else if let error = filter.isEmpty ? model.errors[directory] : search.error {
            ContentUnavailableView {
              Label("Couldn’t Load Files", systemImage: "wifi.exclamationmark")
            } description: {
              Text(error)
            } actions: {
              Button("Try Again") { Task { await refresh() } }
            }
          } else {
            ContentUnavailableView(
              filter.isEmpty ? "Empty Folder" : "No Matching Files",
              systemImage: filter.isEmpty ? "folder" : "magnifyingglass",
              description: Text(
                filter.isEmpty ? "Files added here will appear in this folder." : "Try another filename."))
          }
        }
      }
      .searchable(
        text: $filter,
        prompt: directory == model.root ? "Search files" : "Search \((directory as NSString).lastPathComponent)"
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .task(id: filter) { await updateSearch() }
      .navigationTitle(
        closeBrowser == nil ? (directory == model.root ? "Open File" : (directory as NSString).lastPathComponent) : ""
      )
      .navigationSubtitle(
        closeBrowser == nil ? (relativeParent.isEmpty ? model.rootName : model.rootName + "/" + relativeParent) : ""
      )
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await refresh() }
          }
          .disabled(model.loading.contains(directory) || search.isSearching)
        }
        if let closeBrowser {
          ToolbarItem(placement: .topBarLeading) {
            Button(role: .close, action: closeBrowser)
          }
        }
      }
      .refreshable { await refresh() }
      .task(id: directory) { await model.load(directory) }
    }

    private func updateSearch() async {
      await search.update(query: filter) { query in
        try await model.searchFiles(in: directory, query: query)
      }
    }

    private func refresh() async {
      if filter.isEmpty { await model.load(directory) } else { await updateSearch() }
    }

    private var relativeParent: String {
      guard directory != model.root else { return "" }
      let relative = String(directory.dropFirst(model.root.count + 1))
      return (relative as NSString).deletingLastPathComponent
    }

    private func row(_ entry: ServerFileEntry) -> some View {
      HStack(spacing: 12) {
        FileIcon(path: entry.path, isDirectory: entry.isDirectory, size: 22)
          .frame(width: 28, height: 24)
        Text(filter.isEmpty ? entry.name : model.relativePath(entry.path))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(filter.isEmpty ? .middle : .head)
        Spacer(minLength: 8)
        if entry.path == selectedPath {
          Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
            .accessibilityLabel("Current file")
        }
      }
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
  }
#endif
