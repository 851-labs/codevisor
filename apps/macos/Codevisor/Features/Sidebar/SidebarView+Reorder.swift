import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  func workspaceReorder(_ id: UUID) -> SidebarReorderable<SidebarRowID> {
    SidebarReorderable(
      reorder: reorder, row: .workspace(id),
      lift: {
        guard let region = SidebarWorkspaceDrops.region(dragging: id, in: sidebarRows) else { return }
        reorder.liftItem(id, row: .workspace(id), in: region)
      },
      commit: commitWorkspaceDrop)
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

  @ViewBuilder
  func reorderGhost(for lifted: SidebarReorder<SidebarRowID>.Lifted) -> some View {
    switch lifted.row {
    case let .workspace(id): workspaceGhost(for: id)
    case let .section(.custom(id)): SidebarHeaderGhost(title: environment.workspaceSections.section(id)?.name ?? "")
    case let .group(id): groupGhost(for: id)
    default: EmptyView()
    }
  }

  private func commitWorkspaceDrop(_ drop: SidebarReorder<SidebarRowID>.Drop) {
    guard case let .item(id, region) = drop.lifted.lift, case let .item(target) = drop.target else { return }

    switch target {
    case let .header(section):
      environment.workspaceSections.move(id, to: section)
    case let .insertion(index):
      let placement = region.placement(insertingAt: index, excluding: id)
      environment.placeWorkspace(
        id, at: placement, among: region.siblings(placing: id, at: placement), movingSection: region.movesSections)
    }
  }

  @ViewBuilder
  private func workspaceGhost(for id: UUID) -> some View {
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

  @ViewBuilder
  private func groupGhost(for id: String) -> some View {
    if let heading = workspaceGroups.first(where: { $0.id == id })?.heading {
      SidebarHeaderGhost(title: heading.title, icon: heading.icon)
    }
  }
}
