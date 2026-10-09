import CodevisorCore
import SwiftUI
import UniformTypeIdentifiers

/// An agent's tab overview, Safari's on iPhone: a two-column grid of tab
/// pictures over the workspace. Tap a tab to zoom into it; close one with
/// its button or context menu; hold and drag to reorder. The tab being
/// zoomed is drawn full-size above the grid and settles into its tile.
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
  /// The tabs in the order the user dropped them.
  let onReorder: ([UUID]) -> Void
  let onNewTab: () -> Void
  let onDone: () -> Void

  /// The order while a drag is live; the shared order otherwise.
  @State private var dragOrder: [UUID]?
  @State private var dragging: UUID?
  /// Whether the zooming picture is at full size rather than on its tile.
  /// The overview always mounts zoomed in, over the pane it pictures.
  @State private var isZoomedIn = true
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
    .safeAreaInset(edge: .bottom) { bottomBar }
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
    .onDrag {
      dragging = tab.id
      dragOrder = tabs.map(\.id)
      return NSItemProvider(object: tab.id.uuidString as NSString)
    }
    .onDrop(
      of: [.text],
      delegate: WorkspaceTabDropDelegate(target: tab.id, order: $dragOrder, dragging: $dragging, commit: commitDrag)
    )
    .accessibilityAction(named: "Move Earlier") { move(tab.id, by: -1) }
    .accessibilityAction(named: "Move Later") { move(tab.id, by: 1) }
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

  private var bottomBar: some View {
    HStack {
      Button("New Tab", systemImage: "plus", action: onNewTab)
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
      Spacer()
      Text(tabs.count == 1 ? "1 Tab" : "\(tabs.count) Tabs")
        .font(.headline)
      Spacer()
      Button("Done", action: onDone)
        .buttonStyle(.glass)
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)
    }
    .padding(.horizontal, 20)
    .padding(.bottom, 4)
    .opacity(isZoomedIn ? 0 : 1)
  }

  private func isClosable(_ tab: HomeSidebarTabRow) -> Bool {
    tab.chatSessionId == nil || tab.chatSessionId != homeChatId
  }

  private func commitDrag() {
    guard dragging != nil else { return }
    dragging = nil
    if let dragOrder, dragOrder != tabs.map(\.id) { onReorder(dragOrder) }
  }

  private func move(_ id: UUID, by offset: Int) {
    var order = tabs.map(\.id)
    guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
    order.swapAt(index, index + offset)
    onReorder(order)
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
