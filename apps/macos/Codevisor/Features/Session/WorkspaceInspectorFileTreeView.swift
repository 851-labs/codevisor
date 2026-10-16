import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFileTreeView: View {
  let model: WorkspaceInspectorFileTreeModel
  let activeFilePath: String?
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  @State private var selection: String?
  @State private var folds = SidebarFoldState()

  private var rootPhase: WorkspaceInspectorMediaModel.Phase? {
    guard let root = model.root else { return .loaded }
    if let error = model.errors[root] { return .failed(error) }
    if model.listings[root] != nil { return .loaded }
    return model.slow.contains(root) ? .loading : nil
  }

  var body: some View {
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

  private func tree(_ rows: [WorkspaceInspectorFileTreeModel.Row]) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.root.flatMap { model.listings[$0] } ?? []) { entry in
            WorkspaceInspectorFileTreeNode(
              entry: entry, depth: 0, model: model, folds: folds, selection: selection
            ) { row in
              selection = row.id
              activate(row)
            }
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
      }
      .focusable()
      .focusEffectDisabled()
      .onChange(of: activeFilePath, initial: true) { _, path in
        selection = path
      }
      .onKeyPress(.upArrow) { move(by: -1, in: rows, proxy: proxy) }
      .onKeyPress(.downArrow) { move(by: 1, in: rows, proxy: proxy) }
      .onKeyPress(.rightArrow) { stepIn(rows, proxy: proxy) }
      .onKeyPress(.leftArrow) { stepOut(rows, proxy: proxy) }
      .onKeyPress(.return) {
        guard let row = rows.first(where: { $0.id == selection }) else { return .ignored }
        activate(row)
        return .handled
      }
    }
  }

  private func activate(_ row: WorkspaceInspectorFileTreeModel.Row) {
    if row.entry.isDirectory {
      setExpanded(row.id, !model.expanded.contains(row.id))
    } else {
      onOpen(.file(row.entry.path))
    }
  }

  private func setExpanded(_ path: String, _ isExpanded: Bool) {
    let folds = folds
    let generation = folds.begin(path)
    model.setExpanded(path, isExpanded)
    Task {
      try? await Task.sleep(for: .seconds(Motion.listReflowDuration * 2))
      folds.end(path, generation: generation)
    }
  }

  private func select(_ id: String, proxy: ScrollViewProxy) -> KeyPress.Result {
    selection = id
    proxy.scrollTo(id)
    return .handled
  }

  private func move(
    by offset: Int, in rows: [WorkspaceInspectorFileTreeModel.Row], proxy: ScrollViewProxy
  )
    -> KeyPress.Result
  {
    let current = rows.firstIndex { $0.id == selection }
    let next = current.map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
    guard rows.indices.contains(next) else { return .ignored }
    return select(rows[next].id, proxy: proxy)
  }

  private func stepIn(_ rows: [WorkspaceInspectorFileTreeModel.Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    guard let index = rows.firstIndex(where: { $0.id == selection }), rows[index].entry.isDirectory else {
      return .ignored
    }
    if !model.expanded.contains(rows[index].id) {
      setExpanded(rows[index].id, true)
      return .handled
    }
    let next = index + 1
    guard rows.indices.contains(next), rows[next].depth > rows[index].depth else { return .handled }
    return select(rows[next].id, proxy: proxy)
  }

  private func stepOut(_ rows: [WorkspaceInspectorFileTreeModel.Row], proxy: ScrollViewProxy) -> KeyPress.Result {
    guard let index = rows.firstIndex(where: { $0.id == selection }) else { return .ignored }
    let row = rows[index]
    if row.entry.isDirectory, model.expanded.contains(row.id) {
      setExpanded(row.id, false)
      return .handled
    }
    guard let parent = rows[..<index].last(where: { $0.depth < row.depth }) else { return .ignored }
    return select(parent.id, proxy: proxy)
  }
}

private struct WorkspaceInspectorFileTreeNode: View {
  let entry: ServerFileEntry
  let depth: Int
  let model: WorkspaceInspectorFileTreeModel
  let folds: SidebarFoldState
  let selection: String?
  let onActivate: (WorkspaceInspectorFileTreeModel.Row) -> Void

  var body: some View {
    let row = WorkspaceInspectorFileTreeModel.Row(entry: entry, depth: depth)
    let isExpanded = model.expanded.contains(entry.path)
    let isFolding = folds.isFolding(entry.path)
    VStack(spacing: 0) {
      WorkspaceInspectorFileTreeRow(
        row: row,
        isExpanded: isExpanded,
        isLoading: model.slow.contains(entry.path),
        isSelected: selection == entry.path,
        onActivate: { onActivate(row) }
      )
      .id(entry.path)
      if entry.isDirectory, isExpanded || isFolding, let children = model.listings[entry.path] {
        SidebarFoldingList(shows: isExpanded, appearsFolded: isFolding, spacing: 0) { progress in
          VStack(spacing: 0) {
            ForEach(children) { child in
              WorkspaceInspectorFileTreeNode(
                entry: child, depth: depth + 1, model: model, folds: folds, selection: selection,
                onActivate: onActivate
              )
            }
          }
          .sidebarFoldingRow(true, progress: progress, shows: isExpanded)
        }
      }
    }
  }
}

private struct WorkspaceInspectorFileTreeRow: View {
  let row: WorkspaceInspectorFileTreeModel.Row
  let isExpanded: Bool
  let isLoading: Bool
  let isSelected: Bool
  let onActivate: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let indent: CGFloat = 14

  private var entry: ServerFileEntry { row.entry }

  var body: some View {
    HStack(spacing: 0) {
      ZStack {
        if isLoading {
          ProgressView().controlSize(.mini)
        } else if entry.isDirectory {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .scaleEffect(0.95)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(Motion.listReflow(reduceMotion: reduceMotion), value: isExpanded)
        }
      }
      .frame(width: 10, height: 10)
      .padding(.trailing, 3.5)
      FileIcon(path: entry.path, isDirectory: entry.isDirectory, size: 15)
      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, 6)
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(row.depth) * Self.indent + 4)
    .padding(.trailing, 6)
    .frame(height: 22)
    .contentShape(Rectangle())
    .sidebarRowHover(isSelected: isSelected)
    .onTapGesture(perform: onActivate)
    .help(entry.path)
    .contextMenu {
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(entry.name)
    .accessibilityValue(entry.isDirectory ? (isExpanded ? "Expanded" : "Collapsed") : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(entry.isDirectory ? "" : "Opens the file")
    .accessibilityAction { onActivate() }
  }
}
