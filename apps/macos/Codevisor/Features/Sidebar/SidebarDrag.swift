//  Drag-to-reorder for the sidebar's workspaces.
//
//  The list holds still while you drag. The picked-up row stays in place,
//  dimmed; a copy of it follows the pointer, and a blue insertion line marks
//  where it will land. Nothing moves until release, when the row slides into
//  its new slot and the copy fades away.
//
//  The system drag session (`.draggable`/`.onDrop`) isn't used: its preview
//  belongs to AppKit, which slides it back to the drag's origin whenever the
//  pointer is released off a drop target.

import CodevisorCore
import CodevisorUI
import SwiftUI

/// Workspace row frames, in the sidebar's reorder coordinate space. A plain
/// class, deliberately not observed: frames change on every scroll tick and
/// must not re-evaluate the sidebar; the drag reads them on demand.
@MainActor
final class SidebarDragGeometryStore {
  var workspaces: [UUID: CGRect] = [:]
}

/// A workspace row picked up from the sidebar and following the pointer.
struct SidebarDrag: Equatable {
  let workspaceID: UUID
  /// The row's frame when it was picked up.
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  /// Where a drop would land, as an index among the other rows. Nil when
  /// the drop would leave the row where it is.
  var targetIndex: Int?

  var ghostFrame: CGRect { liftedFrame.offsetBy(dx: 0, dy: translation) }
}

extension SidebarView {
  nonisolated static let reorderSpace = "sidebar.reorder"

  /// The workspace being dragged; its row stays dimmed in place.
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
        // A fast release can carry movement past the last `onChanged`;
        // apply it so the drop lands where the pointer actually let go.
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

  /// The rows a drag reorders, in order: the dragged row's group.
  private func dropCandidates(for id: UUID) -> [UUID] {
    let group = workspaceGroups.first { $0.items.contains { $0.id == id } }?.items ?? []
    return group.map(\.id).filter { dragGeometry.workspaces[$0] != nil }
  }

  /// Moves only the insertion line; the rows stay put until release.
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

  /// Where the insertion line sits: in the gap before the row the drop
  /// would land in front of, or below the last row.
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

  /// The copy under the pointer and the insertion line, drawn over the
  /// list in the reorder space.
  @ViewBuilder
  var reorderOverlay: some View {
    if let drag {
      ZStack(alignment: .topLeading) {
        let frame = drag.ghostFrame
        reorderGhost(for: drag.workspaceID)
          .frame(width: frame.width, height: frame.height)
          .background {
            RoundedRectangle(cornerRadius: 6)
              .fill(.regularMaterial)
              .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
          }
          .opacity(0.92)
          .position(x: frame.midX, y: frame.midY)
        // Over the copy: the copy often hovers right on the drop point.
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

  /// The lifted row's stand-in: the row's label exactly as it renders in
  /// the list.
  @ViewBuilder
  private func reorderGhost(for id: UUID) -> some View {
    if let workspace = environment.navigationStore.workspaceEntries.entry(id).workspace {
      SidebarWorkspaceRowLabel(
        name: workspace.name,
        machineName: rowMachineName(forServer: workspace.serverId),
        status: status(of: workspace)
      )
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
    }
  }
}

/// AppKit's drop indicator: a blue line with a ring at its leading end.
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
