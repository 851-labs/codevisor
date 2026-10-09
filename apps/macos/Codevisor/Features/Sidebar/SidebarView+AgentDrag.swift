import CodevisorCore
import SwiftUI

/// A sidebar row on its way somewhere: where it started, how far the
/// pointer has carried it, and where it would land.
struct AgentSidebarDrag: Equatable {
  let id: UUID
  let title: String
  let start: CGRect
  var translation: CGFloat
  var target: AgentSidebarDropTarget?
}

/// Where a dragged agent would land: in front of a row at that row's level
/// (nested under the same owner, in the same folder), into a folder, or
/// last at the top level.
struct AgentSidebarDropTarget: Equatable {
  /// The row it goes in front of; nil puts it last at its level.
  var before: UUID?
  var owner: UUID?
  var folder: UUID?
  /// Where the insertion line starts and sits, in window coordinates.
  var lineX: CGFloat
  var lineY: CGFloat
}

/// Where each row and folder header sits, in window coordinates. Plain
/// storage: frames change with every scroll, and nothing redraws for them.
final class AgentSidebarFrames {
  var rows: [UUID: CGRect] = [:]
  var folders: [UUID: CGRect] = [:]
}

/// Reordering, nesting and un-nesting agents by dragging their rows. The row
/// follows the pointer and a line shows where it will land, indented to the
/// level it will take: in front of a nested row it nests under that row's
/// owner; among top-level rows it is independent; on a folder it files there.
extension SidebarView {
  /// One row as the sidebar lays it out, with the folder it sits in.
  private struct Placement {
    let entry: AgentSidebarEntry
    let folder: UUID?
  }

  private var placements: [Placement] {
    agentNodes.flatMap { node -> [Placement] in
      switch node {
      case let .agent(row):
        return AgentSidebarEntry.flattening(row).map { Placement(entry: $0, folder: nil) }
      case let .folder(folder, rows):
        guard !folder.collapsed else { return [] }
        let id = UUID(uuidString: folder.id)
        return rows.flatMap { AgentSidebarEntry.flattening($0).map { Placement(entry: $0, folder: id) } }
      case let .project(_, rows):
        return rows.flatMap { AgentSidebarEntry.flattening($0).map { Placement(entry: $0, folder: nil) } }
      }
    }
  }

  func agentDragGesture(_ row: AgentSidebarRow) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .global)
      .onChanged { value in
        if agentDrag?.id != row.id {
          guard let start = agentFrames.rows[row.id] else { return }
          agentDrag = AgentSidebarDrag(id: row.id, title: row.title, start: start, translation: 0)
        }
        agentDrag?.translation = value.translation.height
        agentDrag?.target = dropTarget(at: value.location.y, dragging: row.id)
      }
      .onEnded { _ in
        if let drag = agentDrag, let target = drag.target { drop(drag.id, at: target) }
        withAnimation(.snappy(duration: 0.2)) { agentDrag = nil }
      }
  }

  /// The floating row and the insertion line, drawn over the list.
  func agentDragOverlay(in proxy: GeometryProxy) -> some View {
    let origin = proxy.frame(in: .global).origin
    return ZStack(alignment: .topLeading) {
      if let drag = agentDrag {
        if let target = drag.target {
          Capsule()
            .fill(Color.accentColor)
            .frame(width: max(0, proxy.size.width - (target.lineX - origin.x) - 4), height: 2)
            .offset(x: target.lineX - origin.x, y: target.lineY - origin.y - 1)
        }
        Text(drag.title)
          .lineLimit(1)
          .padding(.leading, 33)
          .frame(width: drag.start.width, height: drag.start.height, alignment: .leading)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
          .offset(x: drag.start.minX - origin.x, y: drag.start.minY + drag.translation - origin.y)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .allowsHitTesting(false)
  }

  private func dropTarget(at y: CGFloat, dragging id: UUID) -> AgentSidebarDropTarget? {
    for (folder, frame) in agentFrames.folders where frame.minY <= y && y < frame.maxY {
      return AgentSidebarDropTarget(before: nil, owner: nil, folder: folder, lineX: frame.minX + 10, lineY: frame.maxY)
    }
    // Not into itself or anything nested under it.
    let candidates = placements.filter { !isWithin($0.entry.row.id, id) }
    for placement in candidates {
      guard let frame = agentFrames.rows[placement.entry.row.id], y < frame.midY else { continue }
      return AgentSidebarDropTarget(
        before: placement.entry.row.id, owner: placement.entry.owner?.id, folder: placement.folder,
        lineX: frame.minX, lineY: frame.minY)
    }
    let topLevel = candidates.first { $0.entry.depth == 0 && $0.folder == nil }
    guard let last = candidates.last.flatMap({ agentFrames.rows[$0.entry.row.id] }) else { return nil }
    let lineX = topLevel.flatMap { agentFrames.rows[$0.entry.row.id]?.minX } ?? last.minX
    return AgentSidebarDropTarget(before: nil, owner: nil, folder: nil, lineX: lineX, lineY: last.maxY)
  }

  private func drop(_ id: UUID, at target: AgentSidebarDropTarget) {
    let all = placements
    if let before = target.before, let row = all.first(where: { $0.entry.row.id == before })?.entry.row {
      if let owner = target.owner, let ownerRow = all.first(where: { $0.entry.row.id == owner })?.entry.row {
        dropAgents([id.uuidString], before: row, under: ownerRow)
      } else {
        dropAgents([id.uuidString], before: row)
      }
    } else if let folder = target.folder {
      dropAgents([id.uuidString], intoFolder: folder)
    } else {
      moveToEnd(id)
    }
  }

  /// Last among the top-level agents, out of any owner or folder.
  private func moveToEnd(_ id: UUID) {
    guard let workspace = environment.workspaces.workspace(id: id) else { return }
    setOwner(of: id, to: nil)
    if workspace.folderId != nil { file(id, into: nil) }
    let last = siblingPositions(inFolder: nil).last { $0.id != id.uuidString }?.position
    guard let position = WorkspacePosition.between(last, nil, id: id) else { return }
    environment.navigationStore.enqueue(
      .reorderWorkspace(workspaceId: id, position: position, expectedRevision: workspace.sidebarOrderRevision),
      machineId: workspace.serverId)
  }
}
