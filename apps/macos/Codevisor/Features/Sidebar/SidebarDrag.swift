import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
final class SidebarDragGeometryStore {
  var workspaces: [UUID: CGRect] = [:]
  var workspacePlacements: [UUID: SidebarRow.Placement] = [:]
  var headings: [String: CGRect] = [:]
}

struct SidebarDrag: Equatable {
  let workspaceID: UUID
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  var targetIndex: Int?
  var sectionTarget: WorkspaceSectionPlacement?

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
        if let section = finished.sectionTarget {
          environment.workspaceSections.move(finished.workspaceID, to: section.sectionID)
        } else if let target = finished.targetIndex {
          commitWorkspaceMove(
            finished.workspaceID, toIndex: target,
            within: dropTargets(for: finished.workspaceID, in: sidebarRows).order)
        }
        withAnimation(Motion.quick(reduceMotion: reduceMotion)) { drag = nil }
      }
  }

  func recordWorkspaceFrame(_ frame: CGRect, for id: UUID, in placement: SidebarRow.Placement) {
    dragGeometry.workspaces[id] = frame
    dragGeometry.workspacePlacements[id] = placement
  }

  func forgetWorkspaceGeometry(for id: UUID, in placement: SidebarRow.Placement) {
    guard dragGeometry.workspacePlacements[id] == placement else { return }

    dragGeometry.workspaces[id] = nil
    dragGeometry.workspacePlacements[id] = nil
  }

  private func dropTargets(for id: UUID, in rows: [SidebarRow]) -> (order: [UUID], frames: [UUID: CGRect]) {
    var order: [UUID] = []
    var frames: [UUID: CGRect] = [:]
    for sibling in SidebarRows.siblings(of: id, in: rows) {
      guard let frame = dragGeometry.workspaces[sibling] else { continue }
      order.append(sibling)
      frames[sibling] = SidebarRows.subtree(of: sibling, in: rows).compactMap { dragGeometry.workspaces[$0] }
        .reduce(frame) { $0.union($1) }
    }
    return (order, frames)
  }

  private func retarget() {
    guard let current = drag else { return }

    let rows = sidebarRows
    let sectionTarget = sectionDropTarget(for: current, in: rows)
    if sectionTarget != current.sectionTarget { drag?.sectionTarget = sectionTarget }
    guard sectionTarget == nil else {
      if current.targetIndex != nil { drag?.targetIndex = nil }
      return
    }

    let (order, frames) = dropTargets(for: current.workspaceID, in: rows)
    guard
      let index = ListReorder.destinationIndex(
        of: current.workspaceID, in: order, frames: frames, midY: current.ghostFrame.midY
      )
    else { return }
    let target = order.firstIndex(of: current.workspaceID) == index ? nil : index
    guard target != current.targetIndex else { return }
    drag?.targetIndex = target
  }

  private func sectionDropTarget(for drag: SidebarDrag, in rows: [SidebarRow]) -> WorkspaceSectionPlacement? {
    guard let row = rows.first(where: { $0.id == .workspace(drag.workspaceID) }),
      let current = WorkspaceSectionPlacement(row)
    else { return nil }

    let center = CGPoint(x: drag.ghostFrame.midX, y: drag.ghostFrame.midY)
    return sectionDropCandidates.first { candidate in
      candidate != current && dragGeometry.headings[candidate.headingID]?.contains(center) == true
    }
  }

  private var sectionDropCandidates: [WorkspaceSectionPlacement] {
    environment.workspaceSections.sections.map { .section($0.id) } + [.unsectioned]
  }

  private func insertionLine(for drag: SidebarDrag) -> CGRect? {
    guard let index = drag.targetIndex else { return nil }
    let (order, frames) = dropTargets(for: drag.workspaceID, in: sidebarRows)
    let others = order.filter { $0 != drag.workspaceID }.compactMap { frames[$0] }
    return SidebarInsertionLine.frame(at: index, among: others)
  }

  @ViewBuilder
  var reorderOverlay: some View {
    if let drag {
      ZStack(alignment: .topLeading) {
        let frame = drag.ghostFrame
        reorderGhost(for: drag.workspaceID)
          .frame(width: frame.width, height: frame.height)
          .sidebarDragLift()
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
      .padding(.horizontal, 10)
    }
  }
}

struct SidebarInsertionLine: View {
  static let height: CGFloat = 7

  static func frame(at index: Int, among others: [CGRect]) -> CGRect? {
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
