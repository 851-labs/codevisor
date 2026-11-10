import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFileTreeView: View {
  typealias Row = WorkspaceInspectorFileTreeModel.Row

  let model: WorkspaceInspectorFileTreeModel
  let activeFilePath: String?
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection = FileTreeSelection()
  @State private var folding = WorkspaceInspectorFileTreeFolding()
  @State private var typeSelect = TypeSelectBuffer()
  @State private var renaming: String?
  @State private var pendingDeletion: [ServerFileEntry] = []
  @State private var dropHoverRow: String?
  @State private var isRootDropTarget = false
  @State private var viewportHeight: CGFloat = 0
  @FocusState private var isTreeFocused: Bool

  private static let springLoadDelay = Duration.milliseconds(700)

  private var dropDirectory: String? {
    if let dropHoverRow { return Self.dropDirectory(for: dropHoverRow, in: model) }
    return isRootDropTarget ? model.root : nil
  }

  private var rootPhase: WorkspaceInspectorMediaModel.Phase? {
    guard let root = model.root else { return .loaded }
    if let error = model.errors[root] { return .failed(error) }
    if model.listings[root] != nil { return .loaded }
    return model.slow.contains(root) ? .loading : nil
  }

  private var isConfirmingDeletion: Binding<Bool> {
    Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
  }

  var body: some View {
    content
      .overlay {
        if dropDirectory == model.root, dropDirectory != nil {
          RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).padding(4)
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        drop(urls, into: model.root)
      } isTargeted: { targeted in
        isRootDropTarget = targeted
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        WorkspaceInspectorFileTransferStatus(transfers: model.transfers)
      }
      .task(id: dropHoverRow) { await springLoad(dropHoverRow) }
      .alert(Self.deletionTitle(pendingDeletion), isPresented: isConfirmingDeletion) {
        Button("Delete", role: .destructive, action: confirmDeletion)
        Button("Cancel", role: .cancel) { pendingDeletion = [] }
      } message: {
        Text("It's deleted right away on the remote machine. You can't undo this.")
      }
  }

  @ViewBuilder
  private var content: some View {
    let rows = model.rows
    if !rows.isEmpty {
      tree(rows)
    } else if let rootPhase {
      WorkspaceInspectorMediaPlaceholder(
        phase: rootPhase, emptyTitle: model.root == nil ? "No Folder" : "No Files", systemImage: "folder",
        emptyDescription: model.root == nil
          ? "This workspace doesn't have a folder to browse."
          : "This workspace's folder is empty.",
        onRetry: { Task { await model.refresh() } }
      )
    } else {
      Color.clear
    }
  }

  private func tree(_ rows: [Row]) -> some View {
    let shown = folding.isIdle ? rows : model.rows(showing: folding.foldingPaths)
    let placements = folding.placements(shown)
    let looks = selectionLooks(shown)
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(shown) { row in
            let placement = placements[row.id]
            rowView(row, in: rows, selection: looks[row.id])
              .padding(.bottom, WorkspaceInspectorFileTreeRow.spacing)
              .modifier(
                WorkspaceInspectorFileTreeFold(
                  progress: placement?.progress ?? 1, index: placement?.index ?? 0, count: placement?.count ?? 1
                )
              )
              .allowsHitTesting(placement == nil)
              .id(row.id)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: viewportHeight, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: clickEmptySpace)
      }
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.height
      } action: { height in
        viewportHeight = height
      }
      .onChange(of: shown.map(\.id)) { _, _ in folding.reveal(model: model, reduceMotion: reduceMotion) }
      .onChange(of: folding.revealing) { _, _ in folding.reveal(model: model, reduceMotion: reduceMotion) }
      .onChange(of: rows.map(\.id)) { _, ids in selection.retain(ids) }
      .focusable()
      .focused($isTreeFocused)
      .focusEffectDisabled()
      .background(ClickOutsideMonitor(isActive: isTreeFocused, onClickOutside: releaseFocusAfterClick))
      .onChange(of: activeFilePath, initial: true) { _, path in
        if let path { selection.select(path) }
      }
      .onKeyPress(phases: .down) { press in handle(press, rows: rows, proxy: proxy) }
      .onCopyCommand { copySelection(in: rows) }
    }
  }

  private func rowView(
    _ row: Row, in rows: [Row], selection look: WorkspaceInspectorFileSelectionBackground.Look?
  ) -> some View {
    WorkspaceInspectorFileTreeRow(
      row: row,
      isExpanded: model.expanded.contains(row.id),
      isLoading: model.slow.contains(row.id),
      selection: look,
      isDropTarget: dropDirectory == row.id,
      isRenaming: renaming == row.id,
      actions: actions(for: row, in: rows)
    )
    .onDrag { model.dragItem(for: row.entry) }
    .dropDestination(for: URL.self) { urls, _ in
      drop(urls, into: Self.dropDirectory(for: row.id, in: model))
    } isTargeted: { targeted in
      hoverDrop(row.id, targeted)
    }
  }

  private func actions(for row: Row, in rows: [Row]) -> WorkspaceInspectorFileTreeRow.Actions {
    let targets = { targets(for: row, in: rows) }
    let isOneOfMany = selection.contains(row.id) && selection.single == nil
    return WorkspaceInspectorFileTreeRow.Actions(
      click: { click(row, in: rows) },
      doubleClick: { onOpen(.file(row.entry.path)) },
      download: { downloadTargets(targets()) },
      copy: { copyTargets(targets()) },
      copyPath: { FileClipboard.writePaths(targets().map(\.path)) },
      rename: isOneOfMany ? nil : { beginRename(row) },
      delete: { requestDelete(targets()) },
      deleteTitle: model.deletesToTrash ? "Move to Trash" : "Delete…",
      commitRename: { name, viaKeyboard in commitRename(row, to: name, viaKeyboard: viaKeyboard) },
      cancelRename: { endRename(refocus: true) }
    )
  }

  private func selectionLooks(_ shown: [Row]) -> [String: WorkspaceInspectorFileSelectionBackground.Look] {
    let isEmphasized = isTreeFocused || renaming != nil
    var looks: [String: WorkspaceInspectorFileSelectionBackground.Look] = [:]
    for (index, row) in shown.enumerated() where selection.contains(row.id) {
      looks[row.id] = WorkspaceInspectorFileSelectionBackground.Look(
        isEmphasized: isEmphasized,
        joinsPrevious: index > 0 && selection.contains(shown[index - 1].id),
        joinsNext: index + 1 < shown.count && selection.contains(shown[index + 1].id)
      )
    }
    return looks
  }

  private func clickEmptySpace() {
    isTreeFocused = true
    selection.clear()
  }

  private func click(_ row: Row, in rows: [Row]) {
    isTreeFocused = true
    let flags = NSApp.currentEvent?.modifierFlags ?? []
    if flags.contains(.command) {
      selection.toggle(row.id)
    } else if flags.contains(.shift) {
      selection.extend(to: row.id, in: rows.map(\.id))
    } else {
      selection.select(row.id)
      activate(row)
    }
  }

  private func targets(for row: Row, in rows: [Row]) -> [ServerFileEntry] {
    guard selection.contains(row.id) else {
      selection.select(row.id)
      return [row.entry]
    }
    return selectedEntries(in: rows)
  }

  private func selectedEntries(in rows: [Row]) -> [ServerFileEntry] {
    rows.filter { selection.contains($0.id) }.map(\.entry)
  }

  private func downloadTargets(_ entries: [ServerFileEntry]) {
    Task { await model.download(entries) }
  }

  private func copyTargets(_ entries: [ServerFileEntry]) {
    Task { await model.copy(entries) }
  }

  private func copySelection(in rows: [Row]) -> [NSItemProvider] {
    copyTargets(selectedEntries(in: rows))
    return []
  }

  private func releaseFocusAfterClick() {
    Task {
      if isTreeFocused { isTreeFocused = false }
    }
  }

  private func handle(_ press: KeyPress, rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    guard renaming == nil,
      let command = FileTreeKeyCommand.command(
        key: press.key, modifiers: press.modifiers, characters: press.characters)
    else { return .ignored }
    return perform(command, rows: rows, proxy: proxy)
  }

  private func perform(_ command: FileTreeKeyCommand, rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    switch command {
    case let .move(offset, extending): return move(by: offset, extending: extending, in: rows, proxy: proxy)
    case .expand: return stepIn(rows, proxy: proxy)
    case .collapse: return stepOut(rows, proxy: proxy)
    case .selectParent: return selectParent(rows, proxy: proxy)
    case .open: return withCursorRow(rows, perform: open)
    case .preview: return withCursorRow(rows, perform: activate)
    case .rename: return withSingleRow(rows, perform: beginRename)
    case .delete:
      requestDelete(selectedEntries(in: rows))
      return .handled
    case .selectAll:
      selection.selectAll(rows.map(\.id))
      return .handled
    case .copy:
      copyTargets(selectedEntries(in: rows))
      return .handled
    case let .typeSelect(characters): return typeToSelect(characters, in: rows, proxy: proxy)
    }
  }

  private func withCursorRow(_ rows: [Row], perform action: (Row) -> Void) -> KeyPress.Result {
    guard let row = rows.first(where: { $0.id == selection.cursor }) else { return .ignored }
    action(row)
    return .handled
  }

  private func withSingleRow(_ rows: [Row], perform action: (Row) -> Void) -> KeyPress.Result {
    guard let row = rows.first(where: { $0.id == selection.single }) else { return .ignored }
    action(row)
    return .handled
  }

  private func reveal(_ id: String, proxy: ScrollViewProxy) -> KeyPress.Result {
    proxy.scrollTo(id)
    return .handled
  }

  private func move(by offset: Int, extending: Bool, in rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    guard let id = selection.move(by: offset, in: rows.map(\.id), extending: extending) else { return .handled }
    return reveal(id, proxy: proxy)
  }

  private func stepIn(_ rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    guard let index = rows.firstIndex(where: { $0.id == selection.cursor }), rows[index].entry.isDirectory else {
      return .ignored
    }
    guard model.expanded.contains(rows[index].id) else {
      setExpanded(rows[index].id, true)
      return .handled
    }
    let next = index + 1
    guard rows.indices.contains(next), rows[next].depth > rows[index].depth else { return .handled }
    selection.select(rows[next].id)
    return reveal(rows[next].id, proxy: proxy)
  }

  private func stepOut(_ rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    guard let row = rows.first(where: { $0.id == selection.cursor }) else { return .ignored }
    guard row.entry.isDirectory, model.expanded.contains(row.id) else { return selectParent(rows, proxy: proxy) }
    setExpanded(row.id, false)
    return .handled
  }

  private func selectParent(_ rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    guard let index = rows.firstIndex(where: { $0.id == selection.cursor }),
      let parent = rows[..<index].last(where: { $0.depth < rows[index].depth })
    else { return .ignored }
    selection.select(parent.id)
    return reveal(parent.id, proxy: proxy)
  }

  private func typeToSelect(_ characters: String, in rows: [Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    let typed = typeSelect.type(characters, at: .now)
    guard let id = TypeSelectBuffer.match(typed, in: rows.map { (id: $0.id, name: $0.entry.name) }) else {
      return .handled
    }
    selection.select(id)
    return reveal(id, proxy: proxy)
  }

  private func activate(_ row: Row) {
    if row.entry.isDirectory {
      setExpanded(row.id, !model.expanded.contains(row.id))
    } else {
      onOpen(.previewFile(row.entry.path))
    }
  }

  private func open(_ row: Row) {
    if row.entry.isDirectory {
      setExpanded(row.id, !model.expanded.contains(row.id))
    } else {
      onOpen(.file(row.entry.path))
    }
  }

  private func setExpanded(_ path: String, _ isExpanded: Bool) {
    folding.setExpanded(path, isExpanded, model: model, reduceMotion: reduceMotion)
  }

  private func beginRename(_ row: Row) {
    selection.select(row.id)
    renaming = row.id
  }

  private func commitRename(_ row: Row, to name: String, viaKeyboard: Bool) {
    endRename(refocus: viaKeyboard)
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed != row.entry.name else { return }
    guard Self.isUsableName(trimmed) else {
      model.transfers.report("“\(trimmed)” can't be used as a name.")
      return
    }
    Task {
      guard let moved = await model.rename(row.entry, to: trimmed) else { return }
      selection.select(moved)
      onOpen(.fileRenamed(from: row.entry.path, to: moved))
    }
  }

  private func endRename(refocus: Bool) {
    renaming = nil
    guard refocus else { return }

    isTreeFocused = false
    Task { isTreeFocused = true }
  }

  private func requestDelete(_ entries: [ServerFileEntry]) {
    guard !entries.isEmpty else { return }
    guard model.deletesToTrash else {
      pendingDeletion = entries
      return
    }
    Task { await model.delete(entries) }
  }

  private func confirmDeletion() {
    let entries = pendingDeletion
    pendingDeletion = []
    Task { await model.delete(entries) }
  }

  private func drop(_ urls: [URL], into directory: String?) -> Bool {
    let files = urls.filter(\.isFileURL)
    guard let directory, !files.isEmpty else { return false }

    Task { await model.drop(files, into: directory) }
    return true
  }

  private func hoverDrop(_ rowId: String, _ targeted: Bool) {
    if targeted {
      dropHoverRow = rowId
    } else if dropHoverRow == rowId {
      dropHoverRow = nil
    }
  }

  private func springLoad(_ rowId: String?) async {
    guard let rowId, model.rows.contains(where: { $0.id == rowId && $0.entry.isDirectory }) else { return }
    guard !model.expanded.contains(rowId) else { return }

    try? await Task.sleep(for: Self.springLoadDelay)
    guard !Task.isCancelled, dropHoverRow == rowId else { return }
    setExpanded(rowId, true)
  }

  private static func dropDirectory(for rowId: String, in model: WorkspaceInspectorFileTreeModel) -> String? {
    guard let row = model.rows.first(where: { $0.id == rowId }) else { return nil }
    if row.entry.isDirectory { return row.id }
    return (row.id as NSString).deletingLastPathComponent
  }

  private static func isUsableName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && name != "." && name != ".."
  }

  private static func deletionTitle(_ entries: [ServerFileEntry]) -> String {
    guard entries.count == 1, let only = entries.first else { return "Delete \(entries.count) items?" }
    return "Delete “\(only.name)”?"
  }
}
