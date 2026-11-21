import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarTabDrag: Equatable {
  let tabID: UUID
  let workspaceID: UUID
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  var targetIndex: Int?

  var ghostFrame: CGRect { liftedFrame.offsetBy(dx: 0, dy: translation) }
}

extension SidebarView {
  func tabReorderGesture(for tabID: UUID, in workspaceID: UUID) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: SidebarReorderSpace.coordinateSpace)
      .onChanged { value in
        if tabDrag?.tabID != tabID {
          guard let frame = dragGeometry.tabs[tabID], frame != .zero else { return }
          withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
            tabDrag = SidebarTabDrag(tabID: tabID, workspaceID: workspaceID, liftedFrame: frame)
          }
        }
        tabDrag?.translation = value.translation.height
        retargetTabDrag()
      }
      .onEnded { value in
        guard tabDrag?.tabID == tabID else { return }
        tabDrag?.translation = value.translation.height
        retargetTabDrag()
        if let finished = tabDrag, let target = finished.targetIndex { commitTabMove(finished, toIndex: target) }
        withAnimation(Motion.quick(reduceMotion: reduceMotion)) { tabDrag = nil }
      }
  }

  func reorderableTabRow(
    _ tabID: UUID, of workspaceID: UUID, reorders: Bool, depth: Int, isSelected: Bool
  ) -> some View {
    tabRow(tabID, of: workspaceID, isSelected: isSelected)
      .opacity(tabDrag?.tabID == tabID ? 0.4 : 1)
      .onGeometryChange(for: CGRect.self) { proxy in
        proxy.frame(in: SidebarReorderSpace.coordinateSpace)
      } action: { frame in
        dragGeometry.tabs[tabID] = frame
      }
      .onDisappear { dragGeometry.tabs[tabID] = nil }
      .modifier(SidebarReorderFrame(reorder: reorder, row: .tab(tabID)))
      .simultaneousGesture(tabReorderGesture(for: tabID, in: workspaceID), including: reorders ? .all : .subviews)
      .padding(.leading, Self.groupIndent * CGFloat(depth))
  }

  @ViewBuilder
  var tabReorderOverlay: some View {
    if let tabDrag {
      ZStack(alignment: .topLeading) {
        let frame = tabDrag.ghostFrame
        tabReorderGhost(for: tabDrag)
          .frame(width: frame.width, height: frame.height)
          .sidebarDragLift()
          .position(x: frame.midX, y: frame.midY)
        if let line = tabInsertionLine(for: tabDrag) {
          SidebarPlacedInsertionLine(frame: line)
        }
      }
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  private func tabOrder(in workspaceID: UUID) -> [UUID] {
    SidebarRows.tabs(of: workspaceID, in: sidebarRows).filter { dragGeometry.tabs[$0] != nil }
  }

  private func retargetTabDrag() {
    guard let current = tabDrag else { return }

    let order = tabOrder(in: current.workspaceID)
    guard
      let index = ListReorder.destinationIndex(
        of: current.tabID, in: order, frames: dragGeometry.tabs, midY: current.ghostFrame.midY)
    else { return }
    let target = order.firstIndex(of: current.tabID) == index ? nil : index
    guard target != current.targetIndex else { return }
    tabDrag?.targetIndex = target
  }

  private func commitTabMove(_ drag: SidebarTabDrag, toIndex index: Int) {
    let order = tabOrder(in: drag.workspaceID)
    let reordered = ListReorder.moving(drag.tabID, to: index, in: order)
    guard reordered != order, let position = reordered.firstIndex(of: drag.tabID) else { return }

    let successor = reordered.indices.contains(position + 1) ? reordered[position + 1] : nil
    environment.workspaceSync.moveTab(drag.tabID, before: successor, inWorkspace: drag.workspaceID)
  }

  private func tabInsertionLine(for drag: SidebarTabDrag) -> CGRect? {
    guard let index = drag.targetIndex else { return nil }

    let others = tabOrder(in: drag.workspaceID).filter { $0 != drag.tabID }.compactMap { dragGeometry.tabs[$0] }
    return SidebarDropLine.frame(at: index, among: others)
  }

  @ViewBuilder
  private func tabReorderGhost(for drag: SidebarTabDrag) -> some View {
    if let store, let workspace = storedWorkspace(drag.workspaceID),
      let tab = workspace.centerTabs.first(where: { $0.id == drag.tabID })
    {
      SidebarTabRowLabel(label: WorkspaceTabLabel(tab, in: workspace, environment: environment, store: store))
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
    }
  }
}
