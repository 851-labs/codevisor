import CodevisorCore
import CodevisorUI
import SwiftUI

/// The navigator's Files tab: the workspace root as an outline. Selecting a
/// file previews it, as in Xcode; double-clicking or Return keeps its tab.
struct FileTreeView: View {
  @Bindable var model: FileTreeModel
  /// The document facing the user. The tree follows it while its row shows.
  let activePath: String?
  let onPreview: (String) -> Void
  let onOpen: (String) -> Void
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    List(selection: $model.selection) {
      ForEach(model.rows) { row in
        FileTreeRowView(row: row, isExpanded: model.expanded.contains(row.id)) {
          Task { await model.toggle(row.id) }
        }
        .navigatorRow()
        .tag(row.id)
      }
    }
    .navigatorListStyle()
    .contextMenu(forSelectionType: String.self) { paths in
      if paths.count == 1, let path = paths.first {
        if model.entry(at: path)?.isDirectory == false {
          Button("Open in Tab") { onOpen(path) }
          Divider()
        }
        Button("Copy Path") { NavigatorList.copy(path) }
        Button("Copy Relative Path") { NavigatorList.copy(model.relativePath(path)) }
      }
    } primaryAction: { paths in
      guard paths.count == 1, let path = paths.first, let entry = model.entry(at: path) else { return }
      if entry.isDirectory {
        Task { await model.toggle(path) }
      } else {
        onOpen(path)
      }
    }
    .onKeyPress(.rightArrow) { expandSelection(true) }
    .onKeyPress(.leftArrow) { expandSelection(false) }
    .onChange(of: model.selection) { _, path in
      // Following the active document is not a request to open it.
      guard let path, path != activePath, model.entry(at: path)?.isDirectory == false else { return }
      onPreview(path)
    }
    .onChange(of: activePath, initial: true) { _, path in followActiveDocument(path) }
    .onChange(of: model.rows) { _, _ in
      if model.selection == nil { followActiveDocument(activePath) }
    }
    .overlay { placeholder }
    // No file watching on the server: re-list what is open while the window
    // is in front, as open documents do.
    .task(id: model.root) {
      await model.refresh()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { break }
        if scenePhase == .active { await model.refresh() }
      }
    }
  }

  @ViewBuilder
  private var placeholder: some View {
    if let error = model.errors[model.root], !model.isLoaded(model.root) {
      ContentUnavailableView {
        Label("Couldn't List Files", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        Button("Retry") { Task { await model.refresh() } }
      }
    } else if !model.isLoaded(model.root) {
      ProgressView().controlSize(.small)
    } else if model.rows.isEmpty {
      ContentUnavailableView("No Files", systemImage: "folder")
    }
  }

  /// Highlights the active document when its row is showing; anything else
  /// clears the highlight, so clicking a highlighted file opens it again.
  private func followActiveDocument(_ path: String?) {
    let target = path.flatMap { path in model.rows.contains { $0.id == path } ? path : nil }
    if model.selection != target { model.selection = target }
  }

  private func expandSelection(_ expand: Bool) -> KeyPress.Result {
    guard let path = model.selection, let entry = model.entry(at: path) else { return .ignored }
    if entry.isDirectory, model.expanded.contains(path) != expand {
      Task { await model.setExpanded(path, expand) }
      return .handled
    }
    let parent = (path as NSString).deletingLastPathComponent
    if !expand, parent != model.root, model.entry(at: parent) != nil {
      model.selection = parent
      return .handled
    }
    return .ignored
  }
}

private struct FileTreeRowView: View {
  let row: FileTreeRow
  let isExpanded: Bool
  let onToggle: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      if row.entry.isDirectory {
        Button(action: onToggle) {
          Image(systemName: "chevron.right")
            .font(.system(size: Typography.IconSize.disclosure, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12, height: NavigatorList.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Collapse \(row.entry.name)" : "Expand \(row.entry.name)")
      } else {
        Color.clear.frame(width: 12)
      }
      FileIcon(path: row.entry.path, isDirectory: row.entry.isDirectory, size: NavigatorList.iconSize)
      Text(row.entry.name)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .frame(height: NavigatorList.rowHeight)
    .padding(.leading, CGFloat(row.depth) * NavigatorList.indent)
    // Ignored files stay reachable, just quieter, as in an editor.
    .opacity(row.entry.isIgnored ? 0.5 : 1)
  }
}
