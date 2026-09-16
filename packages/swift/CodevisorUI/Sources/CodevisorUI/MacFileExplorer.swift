#if canImport(AppKit)
  import AppKit
  import CodevisorCore
  import SwiftUI

  struct MacFileExplorer: View {
    @Bindable var model: FileExplorerModel
    let selectedPath: String
    let open: (String) -> Void
    let openInTab: (String) -> Void

    @Environment(\.closeFileBrowser) private var closeBrowser
    @State private var selection: String?
    @State private var search = FileExplorerSearch()

    private var searchEntries: [ServerFileEntry]? {
      model.filter.isEmpty ? nil : (search.query == model.filter ? search.result?.entries ?? [] : [])
    }

    private var selectedFile: String? {
      let entries = searchEntries ?? model.listings.values.flatMap { $0 }
      return entries.first { $0.path == selection && !$0.isDirectory }?.path
    }

    var body: some View {
      ZStack {
        MacFileOutline(
          model: model, selection: $selection, searchEntries: searchEntries, open: open, openInTab: openInTab)
        if (searchEntries ?? model.listings[model.root] ?? []).isEmpty {
          if !model.filter.isEmpty && (search.isSearching || search.query != model.filter) {
            ProgressView("Searching files…").controlSize(.small)
          } else if model.filter.isEmpty && model.loading.contains(model.root) {
            ProgressView().controlSize(.small)
          } else if let error = model.filter.isEmpty ? model.errors[model.root] : search.error {
            ContentUnavailableView {
              Label("Couldn’t Load Files", systemImage: "wifi.exclamationmark")
            } description: {
              Text(error)
            } actions: {
              Button("Try Again") { Task { await refresh() } }
            }
          } else {
            ContentUnavailableView(
              model.filter.isEmpty ? "Empty Folder" : "No Matching Files",
              systemImage: model.filter.isEmpty ? "folder" : "magnifyingglass")
          }
        }
      }
      .background(Color(nsColor: .controlBackgroundColor), ignoresSafeAreaEdges: [])
      .searchable(text: $model.filter, placement: .toolbar, prompt: "Search files")
      .autocorrectionDisabled()
      .task(id: model.filter) { await updateSearch() }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(spacing: 0) {
          Divider()
          if !model.filter.isEmpty, let notice = search.notice {
            Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 8)
          }
          HStack(spacing: 12) {
            Button("Refresh", systemImage: "arrow.clockwise") {
              Task { await refresh() }
            }
            .labelStyle(.iconOnly)
            .help("Refresh Files")
            .disabled(!model.loading.isEmpty || search.isSearching)
            Spacer()
            if let closeBrowser {
              Button("Cancel", role: .cancel, action: closeBrowser)
                .keyboardShortcut(.cancelAction)
            }
            Button("Open") {
              if let selectedFile { open(selectedFile) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedFile == nil)
          }
          .buttonStyle(.bordered)
          .controlSize(.regular)
          .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
      }
      .task { await model.refresh(selectedPath: selectedPath) }
    }

    private func updateSearch() async {
      await search.update(query: model.filter) { query in
        try await model.searchFiles(in: model.root, query: query)
      }
    }

    private func refresh() async {
      if model.filter.isEmpty { await model.refresh(selectedPath: selectedPath) } else { await updateSearch() }
    }
  }

#endif
