import SwiftUI
import CodevisorCore
import CodevisorUI

/// A compact Finder-style folder picker for remote machines. It opens at the
/// machine root, uses column navigation, and keeps less common actions in the
/// options and context menus.
struct RemoteDirectoryBrowserSheet: View {
  private struct NewFolderTarget: Identifiable {
    let path: String
    let existingNames: Set<String>

    var id: String { path }
  }

  let client: any CodevisorServerClienting
  let machineName: String
  let onChoose: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var model: RemoteDirectoryBrowserModel
  @State private var showingGoTo = false
  @State private var goToText = ""
  @State private var newFolderTarget: NewFolderTarget?
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
    _model = State(
      initialValue: RemoteDirectoryBrowserModel(machineName: machineName) { path, showHidden in
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
      columnBrowser
      Divider()
      footer
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    .sheet(item: $newFolderTarget) { target in
      NewRemoteFolderSheet(
        machineName: machineName,
        parentPath: target.path,
        existingNames: target.existingNames,
        create: { path in try await client.createDirectory(path: path) }
      ) { createdPath in
        Task {
          await model.revealCreatedFolder(createdPath, parentPath: target.path)
          focusedColumn = model.columns.last?.id
        }
      }
    }
    .background(hiddenShortcuts)
    .frame(
      minWidth: 640, idealWidth: 760, maxWidth: .infinity,
      minHeight: 400, idealHeight: 450, maxHeight: .infinity
    )
    .task {
      await model.open("/")
      focusedColumn = model.columns.first?.id
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text("Choose Folder")
        .font(.headline)
      Spacer()
      optionsMenu
    }
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
    .contentShape(Rectangle())
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
    .contextMenu {
      Button("New Folder…") {
        presentNewFolder(in: column)
      }
      .disabled(column.listing == nil)
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
      Button("New Folder…") { presentNewFolder() }
        .disabled(currentColumn == nil)
      Divider()
      Button("Go to Folder…") { openGoTo() }
      Toggle("Show Hidden Folders", isOn: showHiddenBinding)
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
  /// visible chrome: ⇧⌘N new folder, ⇧⌘. hidden folders, ⇧⌘G go to
  /// folder, ⌘↑ enclosing folder.
  private var hiddenShortcuts: some View {
    Group {
      Button("") { presentNewFolder() }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(currentColumn == nil)
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

  private var currentColumn: RemoteDirectoryBrowserModel.Column? {
    guard let column = model.columns.last, column.listing != nil else { return nil }
    return column
  }

  private func presentNewFolder() {
    guard let currentColumn else { return }
    presentNewFolder(in: currentColumn)
  }

  private func presentNewFolder(in column: RemoteDirectoryBrowserModel.Column) {
    guard let listing = column.listing else { return }
    newFolderTarget = NewFolderTarget(
      path: listing.path,
      existingNames: Set(listing.entries.map(\.name))
    )
  }
}
