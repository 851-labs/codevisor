import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarWorkspaceGeometry: Equatable {
  var header: CGRect = .zero
  var section: CGRect = .zero
}

@MainActor
final class ClassicSidebarDragGeometryStore {
  var workspaces: [UUID: SidebarWorkspaceGeometry] = [:]
  var tabs: [UUID: CGRect] = [:]
}

enum SidebarDragItem: Equatable {
  case workspace(UUID)
  case tab(UUID, workspaceID: UUID)

  var id: UUID {
    switch self {
    case let .workspace(id), let .tab(id, _): id
    }
  }
}

struct ClassicSidebarDrag: Equatable {
  let item: SidebarDragItem
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  var targetIndex: Int?

  var ghostFrame: CGRect { liftedFrame.offsetBy(dx: 0, dy: translation) }
}

extension ClassicSidebarView {
  nonisolated static let reorderSpace = "sidebar.reorder"

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
            drag = ClassicSidebarDrag(item: item, liftedFrame: frame)
          }
        }
        drag?.translation = value.translation.height
        retarget()
      }
      .onEnded { value in
        guard drag?.item == item else { return }
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

  private func insertionLine(for drag: ClassicSidebarDrag) -> CGRect? {
    guard let index = drag.targetIndex else { return nil }
    let candidates = dropCandidates(for: drag.item)
    let others = candidates.order.filter { $0 != drag.item.id }.compactMap { candidates.frames[$0] }
    guard !others.isEmpty else { return nil }
    let y: CGFloat
    let span: CGRect
    switch drag.item {
    case .workspace:
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

  @ViewBuilder
  var reorderOverlay: some View {
    if let drag {
      ZStack(alignment: .topLeading) {
        let frame = drag.ghostFrame
        reorderGhost(for: drag.item)
          .frame(width: frame.width, height: frame.height)
          .background {
            let inset = drag.item.id == draggingWorkspaceID ? SidebarWorkspaceHeader.topPadding - 4 : 0
            RoundedRectangle(cornerRadius: 6)
              .fill(.regularMaterial)
              .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
              .padding(.top, inset)
          }
          .opacity(0.92)
          .position(x: frame.midX, y: frame.midY)
        if let line = insertionLine(for: drag) {
          ClassicSidebarInsertionLine()
            .frame(width: line.width, height: ClassicSidebarInsertionLine.height)
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

struct ClassicSidebarInsertionLine: View {
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
