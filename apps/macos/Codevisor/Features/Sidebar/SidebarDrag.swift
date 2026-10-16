import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
final class SidebarDragGeometryStore {
  var workspaces: [UUID: CGRect] = [:]
}

struct SidebarDrag: Equatable {
  let workspaceID: UUID
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  var targetIndex: Int?

  var ghostFrame: CGRect { liftedFrame.offsetBy(dx: 0, dy: translation) }
}

extension SidebarView {
  nonisolated static let reorderSpace = "sidebar.reorder"

  var draggingID: UUID? { drag?.workspaceID }

  func reorderGesture(for id: UUID) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
      .onChanged { value in
        if drag?.workspaceID != id {
          guard let frame = dragGeometry.workspaces[id], frame != .zero else { return }
          withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
            drag = SidebarDrag(workspaceID: id, liftedFrame: frame)
          }
        }
        drag?.translation = value.translation.height
        retarget()
      }
      .onEnded { value in
        guard drag?.workspaceID == id else { return }
        drag?.translation = value.translation.height
        retarget()
        guard let finished = drag else { return }
        withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
          if let target = finished.targetIndex {
            commitWorkspaceMove(
              finished.workspaceID, toIndex: target, within: dropCandidates(for: finished.workspaceID))
          }
          drag = nil
        }
      }
  }

  func recordWorkspaceFrame(_ frame: CGRect, for id: UUID) {
    dragGeometry.workspaces[id] = frame
  }

  func forgetWorkspaceGeometry(for id: UUID) {
    dragGeometry.workspaces[id] = nil
  }

  private func dropCandidates(for id: UUID) -> [UUID] {
    let group =
      workspaceGroups.first { $0.items.contains { $0.id == id } }?.items
      ?? botChildren(containing: id) ?? []
    return group.map(\.id).filter { dragGeometry.workspaces[$0] != nil }
  }

  private func retarget() {
    guard let current = drag else { return }
    let order = dropCandidates(for: current.workspaceID)
    guard
      let index = ListReorder.destinationIndex(
        of: current.workspaceID, in: order, frames: dragGeometry.workspaces, midY: current.ghostFrame.midY
      )
    else { return }
    let target = order.firstIndex(of: current.workspaceID) == index ? nil : index
    guard target != current.targetIndex else { return }
    drag?.targetIndex = target
  }

  private func insertionLine(for drag: SidebarDrag) -> CGRect? {
    guard let index = drag.targetIndex else { return nil }
    let others = dropCandidates(for: drag.workspaceID)
      .filter { $0 != drag.workspaceID }
      .compactMap { dragGeometry.workspaces[$0] }
    guard !others.isEmpty else { return nil }
    let y: CGFloat
    let span: CGRect
    if others.indices.contains(index) {
      span = others[index]
      y = index > 0 ? (others[index - 1].maxY + span.minY) / 2 : span.minY - 1
    } else {
      span = others[others.count - 1]
      y = span.maxY + 1
    }
    return CGRect(x: span.minX, y: y, width: span.width, height: 0)
  }

  @ViewBuilder
  var reorderOverlay: some View {
    if let drag {
      ZStack(alignment: .topLeading) {
        let frame = drag.ghostFrame
        reorderGhost(for: drag.workspaceID)
          .frame(width: frame.width, height: frame.height)
          .background {
            RoundedRectangle.sidebarRow
              .fill(.regularMaterial)
              .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
          }
          .opacity(0.92)
          .position(x: frame.midX, y: frame.midY)
        if let line = insertionLine(for: drag) {
          SidebarInsertionLine()
            .frame(width: line.width, height: SidebarInsertionLine.height)
            .position(x: line.midX, y: line.minY)
        }
      }
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  @ViewBuilder
  private func reorderGhost(for id: UUID) -> some View {
    if let entry = listedSidebarItems.first(where: { $0.id == id }), let item = listItem(for: entry) {
      SidebarWorkspaceRowLabel(
        name: item.workspace.name,
        subtitle: rowSubtitle(for: item.workspace),
        icon: icon(for: item),
        store: store
      )
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
    }
  }
}

struct SidebarInsertionLine: View {
  static let height: CGFloat = 7

  var body: some View {
    HStack(spacing: 0) {
      Circle()
        .strokeBorder(Color.accentColor, lineWidth: 2)
        .frame(width: Self.height, height: Self.height)
      Rectangle()
        .fill(Color.accentColor)
        .frame(height: 2)
    }
  }
}
