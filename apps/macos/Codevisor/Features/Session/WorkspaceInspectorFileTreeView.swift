import AppKit
import CodevisorClient
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorFileTreeView: View {
  let model: WorkspaceInspectorFileTreeModel
  let activeFilePath: String?
  let onOpen: (WorkspaceInspectorView.Destination) -> Void

  private struct Fold {
    var progress: CGFloat
    let generation: Int
  }

  private struct FoldPlacement {
    let progress: CGFloat
    let index: Int
    let count: Int
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selection: String?
  @State private var folding: [String: Fold] = [:]
  @State private var revealing: Set<String> = []
  @State private var foldGeneration = 0

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
    let shown = folding.isEmpty ? rows : model.rows(showing: folding.keys)
    let placements = foldPlacements(shown)
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(shown) { row in
            let placement = placements[row.id]
            WorkspaceInspectorFileTreeRow(
              row: row,
              isExpanded: model.expanded.contains(row.id),
              isLoading: model.slow.contains(row.id),
              isSelected: selection == row.id,
              onActivate: {
                selection = row.id
                activate(row)
              },
              onKeep: { onOpen(.file(row.entry.path)) }
            )
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
      }
      .onChange(of: shown.map(\.id)) { _, _ in reveal() }
      .onChange(of: revealing) { _, _ in reveal() }
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
      onOpen(.previewFile(row.entry.path))
    }
  }

  private func setExpanded(_ path: String, _ isExpanded: Bool) {
    foldGeneration += 1
    let generation = foldGeneration
    if isExpanded {
      folding[path] = Fold(progress: 0, generation: generation)
      revealing.insert(path)
      model.setExpanded(path, true)
    } else {
      revealing.remove(path)
      folding[path] = Fold(progress: folding[path]?.progress ?? 1, generation: generation)
      model.setExpanded(path, false)
      withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { folding[path]?.progress = 0 }
      endFold(path, generation: generation)
    }
  }

  private func reveal() {
    for path in revealing where model.listings[path] != nil || !model.expanded.contains(path) {
      revealing.remove(path)
      guard model.expanded.contains(path), let generation = folding[path]?.generation else {
        folding[path] = nil
        continue
      }
      withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { folding[path]?.progress = 1 }
      endFold(path, generation: generation)
    }
  }

  private func endFold(_ path: String, generation: Int) {
    Task {
      try? await Task.sleep(for: .seconds(Motion.listReflowDuration * 2))
      if folding[path]?.generation == generation { folding[path] = nil }
    }
  }

  private func foldPlacements(
    _ rows: [WorkspaceInspectorFileTreeModel.Row]
  ) -> [String: FoldPlacement] {
    var placements: [String: FoldPlacement] = [:]
    guard !folding.isEmpty else { return placements }
    var index = 0
    while index < rows.count {
      let row = rows[index]
      index += 1
      guard let fold = folding[row.id] else { continue }
      let block = rows[index...].prefix { $0.depth > row.depth }
      for (offset, child) in block.enumerated() {
        placements[child.id] = FoldPlacement(progress: fold.progress, index: offset, count: block.count)
      }
      index += block.count
    }
    return placements
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

private struct WorkspaceInspectorFileTreeFold: ViewModifier, Animatable {
  var progress: CGFloat
  let index: Int
  let count: Int

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    let height = WorkspaceInspectorFileTreeRow.height + WorkspaceInspectorFileTreeRow.spacing
    let visible = min(height, max(0, progress * CGFloat(count) * height - CGFloat(index) * height))
    content
      .frame(height: visible, alignment: .top)
      .clipped()
      .opacity(progress)
  }
}

private struct WorkspaceInspectorFileTreeRow: View {
  let row: WorkspaceInspectorFileTreeModel.Row
  let isExpanded: Bool
  let isLoading: Bool
  let isSelected: Bool
  let onActivate: () -> Void
  let onKeep: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let height: CGFloat = 22
  static let spacing: CGFloat = 1
  private static let indent: CGFloat = 14

  private var entry: ServerFileEntry { row.entry }

  private var expansionValue: LocalizedStringKey {
    guard entry.isDirectory else { return "" }
    return isExpanded ? "Expanded" : "Collapsed"
  }

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
    .frame(height: Self.height)
    .contentShape(Rectangle())
    .sidebarRowHover(isSelected: isSelected)
    .onTapGesture {
      if !entry.isDirectory, let event = NSApp.currentEvent, event.type == .leftMouseUp, event.clickCount > 1 {
        onKeep()
      } else {
        onActivate()
      }
    }
    .help(entry.path)
    .contextMenu {
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(entry.name)
    .accessibilityValue(expansionValue)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(entry.isDirectory ? "" : "Opens the file")
    .accessibilityAction { onActivate() }
  }
}
