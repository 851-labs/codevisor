//  Drag-to-reorder for the sidebar's workspaces and tabs.
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

/// Where a workspace section sits, in the sidebar's reorder coordinate space.
struct SidebarWorkspaceGeometry: Equatable {
  /// The header row alone: what the workspace's drag copy mimics.
  var header: CGRect = .zero
  /// The header plus its tab rows: what a dragged workspace is compared
  /// against.
  var section: CGRect = .zero
}

/// Frames reported by every mounted section and tab. A plain class,
/// deliberately not observed: frames change on every scroll tick and must
/// not re-evaluate the sidebar; the drag reads them on demand.
@MainActor
final class SidebarDragGeometryStore {
  var workspaces: [UUID: SidebarWorkspaceGeometry] = [:]
  /// A tab's rows (one per pane of a split).
  var tabs: [UUID: CGRect] = [:]
}

/// What a sidebar drag picked up. Tabs move only within their workspace.
enum SidebarDragItem: Equatable {
  case workspace(UUID)
  case tab(UUID, workspaceID: UUID)

  var id: UUID {
    switch self {
    case let .workspace(id), let .tab(id, _): id
    }
  }
}

/// A row picked up from the sidebar and following the pointer.
struct SidebarDrag: Equatable {
  let item: SidebarDragItem
  /// The row's frame when it was picked up.
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  /// Where a drop would land, as an index among the other rows. Nil when
  /// the drop would leave the row where it is.
  var targetIndex: Int?

  var ghostFrame: CGRect { liftedFrame.offsetBy(dx: 0, dy: translation) }
}

extension SidebarView {
  static let reorderSpace = "sidebar.reorder"

  /// The workspace or tab being dragged; its row stays dimmed in place.
  var draggingID: UUID? { drag?.item.id }

  private var draggingWorkspaceID: UUID? {
    if case let .workspace(id) = drag?.item { id } else { nil }
  }

  func reorderGesture(for item: SidebarDragItem) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
      .onChanged { value in
        if drag?.item != item {
          guard let frame = liftFrame(of: item), frame != .zero else { return }
          withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
            drag = SidebarDrag(item: item, liftedFrame: frame)
          }
        }
        drag?.translation = value.translation.height
        retarget()
      }
      .onEnded { value in
        guard drag?.item == item else { return }
        // A fast release can carry movement past the last `onChanged`;
        // apply it so the drop lands where the pointer actually let go.
        drag?.translation = value.translation.height
        retarget()
        guard let finished = drag else { return }
        withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
          if let target = finished.targetIndex {
            commitMove(finished.item, toIndex: target)
          }
          drag = nil
        }
      }
  }

  func recordWorkspaceHeaderFrame(_ frame: CGRect, for id: UUID) {
    dragGeometry.workspaces[id, default: .init()].header = frame
  }

  func recordWorkspaceSectionFrame(_ frame: CGRect, for id: UUID) {
    dragGeometry.workspaces[id, default: .init()].section = frame
  }

  func recordTabFrame(_ frame: CGRect, for id: UUID) {
    dragGeometry.tabs[id] = frame
  }

  func forgetWorkspaceGeometry(for id: UUID) {
    dragGeometry.workspaces[id] = nil
  }

  func forgetTabGeometry(for id: UUID) {
    dragGeometry.tabs[id] = nil
  }

  private func liftFrame(of item: SidebarDragItem) -> CGRect? {
    switch item {
    case let .workspace(id): dragGeometry.workspaces[id]?.header
    case let .tab(id, _): dragGeometry.tabs[id]
    }
  }

  /// The rows a drag reorders, in order, with their frames.
  private func dropCandidates(for item: SidebarDragItem) -> (order: [UUID], frames: [UUID: CGRect]) {
    switch item {
    case .workspace:
      let frames = dragGeometry.workspaces.compactMapValues { $0.section == .zero ? nil : $0.section }
      return (listedSidebarItems.map(\.id).filter { frames[$0] != nil }, frames)
    case let .tab(_, workspaceID):
      let tabs = environment.navigationStore.workspaceEntries.entry(workspaceID).workspace?.centerTabs ?? []
      return (tabs.map(\.id).filter { dragGeometry.tabs[$0] != nil }, dragGeometry.tabs)
    }
  }

  /// Moves only the insertion line; the rows stay put until release.
  private func retarget() {
    guard let current = drag else { return }
    let candidates = dropCandidates(for: current.item)
    guard
      let index = ListReorder.destinationIndex(
        of: current.item.id, in: candidates.order, frames: candidates.frames, midY: current.ghostFrame.midY
      )
    else { return }
    let target = candidates.order.firstIndex(of: current.item.id) == index ? nil : index
    guard target != current.targetIndex else { return }
    drag?.targetIndex = target
  }

  /// Saves a finished drag: one move, sent once the row is released.
  private func commitMove(_ item: SidebarDragItem, toIndex index: Int) {
    switch item {
    case let .workspace(id):
      commitWorkspaceMove(id, toIndex: index)
    case let .tab(id, workspaceID):
      let others = dropCandidates(for: item).order.filter { $0 != id }
      let successor = others.indices.contains(index) ? others[index] : nil
      environment.workspaceSync.moveTab(id, before: successor, inWorkspace: workspaceID)
    }
  }

  /// Where the insertion line sits: in the gap before the row the drop
  /// would land in front of, or below the last row.
  private func insertionLine(for drag: SidebarDrag) -> CGRect? {
    guard let index = drag.targetIndex else { return nil }
    let candidates = dropCandidates(for: drag.item)
    let others = candidates.order.filter { $0 != drag.item.id }.compactMap { candidates.frames[$0] }
    guard !others.isEmpty else { return nil }
    let y: CGFloat
    let span: CGRect
    switch drag.item {
    case .workspace:
      // A section opens with its header's top padding; the line sits in
      // that space, between the last tab above and the name below.
      let inset = SidebarWorkspaceHeader.topPadding / 2
      if others.indices.contains(index) {
        span = others[index]
        y = span.minY + inset
      } else {
        span = others[others.count - 1]
        y = span.maxY + inset
      }
    case .tab:
      if others.indices.contains(index) {
        span = others[index]
        y = index > 0 ? (others[index - 1].maxY + span.minY) / 2 : span.minY - 1
      } else {
        span = others[others.count - 1]
        y = span.maxY + 1
      }
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
        reorderGhost(for: drag.item)
          .frame(width: frame.width, height: frame.height)
          .background {
            // A header's top padding is spacing above the section, not
            // part of the row, so the card leaves most of it out.
            let inset = drag.item.id == draggingWorkspaceID ? SidebarWorkspaceHeader.topPadding - 4 : 0
            RoundedRectangle(cornerRadius: 6)
              .fill(.regularMaterial)
              .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
              .padding(.top, inset)
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

  @ViewBuilder
  private func reorderGhost(for item: SidebarDragItem) -> some View {
    switch item {
    case let .workspace(id):
      if let workspace = environment.navigationStore.workspaceEntries.entry(id).workspace {
        SidebarWorkspaceDragGhost(name: workspace.name, machineName: machineName(forServer: workspace.serverId))
      }
    case let .tab(id, workspaceID):
      if let entry = listedSidebarItems.first(where: { $0.id == workspaceID }),
        let item = listItem(for: entry),
        let tab = item.workspace.centerTabs.first(where: { $0.id == id })
      {
        tabRows(tab, in: item, routesSelection: routesSelectedSession(item.workspace))
      }
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

/// The lifted header's stand-in: the header exactly as it renders in the
/// list — same label, insets, and color.
struct SidebarWorkspaceDragGhost: View {
  let name: String
  let machineName: String?

  var body: some View {
    HStack(spacing: 0) {
      SidebarWorkspaceHeaderLabel(name: name, machineName: machineName)
      Spacer(minLength: 0)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, SidebarWorkspaceHeader.horizontalPadding)
    .padding(.top, SidebarWorkspaceHeader.topPadding)
    .padding(.bottom, SidebarWorkspaceHeader.bottomPadding)
  }
}
