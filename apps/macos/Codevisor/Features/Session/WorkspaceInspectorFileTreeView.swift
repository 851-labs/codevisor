import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFileTreeView: View {
  let model: WorkspaceInspectorFileTreeModel
  let activeFilePath: String?
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: String?

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
          ForEach(rows) { row in
            WorkspaceInspectorFileTreeRow(
              row: row,
              isExpanded: model.expanded.contains(row.id),
              isLoading: model.slow.contains(row.id),
              isSelected: selection == row.id,
              onActivate: {
                selection = row.id
                activate(row)
              }
            )
            .id(row.id)
          }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: rows.map(\.id))
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
    withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
      model.setExpanded(path, isExpanded)
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

private struct WorkspaceInspectorFileTreeRow: View {
  let row: WorkspaceInspectorFileTreeModel.Row
  let isExpanded: Bool
  let isLoading: Bool
  let isSelected: Bool
  let onActivate: () -> Void

  private static let indent: CGFloat = 14

  private var entry: ServerFileEntry { row.entry }

  var body: some View {
    HStack(spacing: 0) {
      Group {
        if isLoading {
          ProgressView().controlSize(.mini)
        } else if entry.isDirectory {
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
      }
      .frame(width: 10, height: 10)
      .padding(.trailing, 2)
      FileIcon(path: entry.path, isDirectory: entry.isDirectory, size: 16)
      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, 6)
      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(row.depth) * Self.indent + 5)
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
