import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

/// One page of the tab overview: a two-column grid of a workspace's tab
/// pictures, Safari's on iPhone. Tap a tab to open it; close one with its
/// button or context menu; hold and drag to reorder. On the agent's own
/// page the tab being zoomed is drawn above the grid, between full size and
/// its tile.
struct WorkspaceTabGrid: View {
  let tabs: [HomeSidebarTabRow]
  let serverId: String
  let selectedId: UUID?
  let homeChatId: UUID?
  let aspectRatio: CGFloat
  let phase: WorkspaceTabOverview
  let zoom: Animation?
  /// The opening or closing zoom has finished.
  let onSettled: () -> Void
  let onSelect: (UUID) -> Void
  let onClose: (UUID) -> Void
  let onCloseOthers: (UUID) -> Void
  /// The tabs in the order the user dropped them; nil where they can't be
  /// reordered from here.
  let onReorder: (([UUID]) -> Void)?
  /// Whether the zooming picture is at full size rather than on its tile.
  /// The agent's own page mounts zoomed in, over the pane it pictures.
  @Binding var isZoomedIn: Bool

  /// The order while a drag is live; the shared order otherwise.
  @State private var dragOrder: [UUID]?
  @State private var dragging: UUID?
  @State private var pictureFrames = WorkspaceTabPictureFrames()

  static let coordinateSpace = "workspace-tab-grid"

  /// The tab whose picture is zooming.
  private var zoomingId: UUID? {
    switch phase {
    case let .opening(id), let .closing(id): id
    case .open: nil
    }
  }

  private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

  private var ordered: [HomeSidebarTabRow] {
    guard let dragOrder else { return tabs }
    let byId = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return dragOrder.compactMap { byId[$0] }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVGrid(columns: columns, spacing: 20) {
          ForEach(ordered) { tab in tile(tab) }
        }
        .padding(16)
      }
      // Clear of the overview's bottom bar, which floats over the pages.
      .contentMargins(.bottom, 64, for: .scrollContent)
      .onAppear {
        if let selectedId { proxy.scrollTo(selectedId, anchor: .center) }
      }
    }
    .coordinateSpace(.named(Self.coordinateSpace))
    .background(Color(.systemGroupedBackground))
    // A drop that misses every tile still ends the drag where it is.
    .onDrop(of: [.text], isTargeted: nil) { _ in
      commitDrag()
      return true
    }
    .overlay { GeometryReader { zoomLayer(in: $0.frame(in: .local)) } }
    .task(id: tabs.map(\.id)) { await PaneSnapshotCache.shared.loadPersisted(tabs.map(\.id)) }
    .task(id: phase) { await settle(phase) }
    .onChange(of: tabs.map(\.id)) { _, _ in
      if dragging == nil { dragOrder = nil }
    }
  }

  private func tile(_ tab: HomeSidebarTabRow) -> some View {
    let isClosable = isClosable(tab)
    return WorkspaceTabTile(
      tab: tab, serverId: serverId, aspectRatio: aspectRatio, isSelected: tab.id == selectedId,
      isClosable: isClosable, isExpanded: tab.id == zoomingId,
      onClose: { onClose(tab.id) },
      onPictureFrame: { pictureFrames.frames[tab.id] = $0 }
    )
    .id(tab.id)
    .opacity(dragging == tab.id ? 0.4 : 1)
    .onTapGesture { onSelect(tab.id) }
    .contextMenu {
      if isClosable {
        Button("Close Tab", systemImage: "xmark", role: .destructive) { onClose(tab.id) }
      }
      if tabs.contains(where: { $0.id != tab.id && self.isClosable($0) }) {
        Button("Close Other Tabs", systemImage: "xmark.square") { onCloseOthers(tab.id) }
      }
    }
    .modifier(reorderable(tab))
  }

  private func reorderable(_ tab: HomeSidebarTabRow) -> WorkspaceTabReordering {
    WorkspaceTabReordering(
      tab: tab, isEnabled: onReorder != nil, tabIds: tabs.map(\.id), dragOrder: $dragOrder, dragging: $dragging,
      commit: commitDrag, move: { move(tab.id, by: $0) })
  }

  /// The zooming tab's picture, between full size and its tile.
  @ViewBuilder
  private func zoomLayer(in bounds: CGRect) -> some View {
    if let zoomingId, let tab = tabs.first(where: { $0.id == zoomingId }) {
      let tile = pictureFrames.frames[zoomingId] ?? bounds.insetBy(dx: bounds.width / 3, dy: bounds.height / 3)
      let frame = isZoomedIn ? bounds : tile
      WorkspaceTabPreview(tab: tab, serverId: serverId)
        .frame(width: frame.width, height: frame.height)
        .clipShape(.rect(cornerRadius: isZoomedIn ? 0 : WorkspaceTabTile.cornerRadius))
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
    }
  }

  /// Runs the zoom the phase asks for, then reports it done.
  private func settle(_ phase: WorkspaceTabOverview) async {
    let zoomIn: Bool
    switch phase {
    case let .opening(id):
      // Wait (a few frames at most) for the lazy grid to place the tile.
      for _ in 0..<10 where pictureFrames.frames[id] == nil {
        try? await Task.sleep(for: .milliseconds(16))
      }
      zoomIn = false
    case .closing: zoomIn = true
    case .open: return
    }
    guard !Task.isCancelled else { return }
    withAnimation(zoom) {
      isZoomedIn = zoomIn
    } completion: {
      onSettled()
    }
  }

  private func isClosable(_ tab: HomeSidebarTabRow) -> Bool {
    tab.chatSessionId == nil || tab.chatSessionId != homeChatId
  }

  private func commitDrag() {
    guard dragging != nil else { return }
    dragging = nil
    if let dragOrder, dragOrder != tabs.map(\.id) { onReorder?(dragOrder) }
  }

  private func move(_ id: UUID, by offset: Int) {
    var order = tabs.map(\.id)
    guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
    order.swapAt(index, index + offset)
    onReorder?(order)
  }
}

/// Hold-and-drag reordering of a tile, and its accessibility equivalent.
private struct WorkspaceTabReordering: ViewModifier {
  let tab: HomeSidebarTabRow
  let isEnabled: Bool
  let tabIds: [UUID]
  @Binding var dragOrder: [UUID]?
  @Binding var dragging: UUID?
  let commit: () -> Void
  let move: (Int) -> Void

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .onDrag {
          dragging = tab.id
          dragOrder = tabIds
          return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(
          of: [.text],
          delegate: WorkspaceTabDropDelegate(target: tab.id, order: $dragOrder, dragging: $dragging, commit: commit)
        )
        .accessibilityAction(named: "Move Earlier") { move(-1) }
        .accessibilityAction(named: "Move Later") { move(1) }
    } else {
      content
    }
  }
}

/// Moves the dragged tab into each tile's slot as the finger passes it.
private struct WorkspaceTabDropDelegate: DropDelegate {
  let target: UUID
  @Binding var order: [UUID]?
  @Binding var dragging: UUID?
  let commit: () -> Void

  func dropEntered(info: DropInfo) {
    guard let dragging, dragging != target, var current = order,
      let from = current.firstIndex(of: dragging), let to = current.firstIndex(of: target)
    else { return }
    current.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    withAnimation(.smooth(duration: 0.25)) { order = current }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

  func performDrop(info: DropInfo) -> Bool {
    commit()
    return true
  }
}

/// Where each tile's picture sits in the grid. Written as tiles lay out and
/// read only when a zoom starts, so it stays out of observed state.
final class WorkspaceTabPictureFrames {
  var frames: [UUID: CGRect] = [:]
}
