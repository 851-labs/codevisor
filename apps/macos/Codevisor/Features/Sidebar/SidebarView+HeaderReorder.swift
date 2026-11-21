import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  var reordersGroups: Bool { grouping != .flat }

  func headerReorder(_ header: SidebarRowID, isEnabled: Bool = true) -> SidebarReorderable<SidebarRowID> {
    SidebarReorderable(
      reorder: reorder, row: header, isEnabled: isEnabled,
      lift: {
        guard let blocks = SidebarWorkspaceDrops.blocks(dragging: header, in: sidebarRows) else { return }
        reorder.liftBlock(header, in: blocks)
      },
      commit: commitHeaderDrop)
  }

  private func commitHeaderDrop(_ drop: SidebarReorder<SidebarRowID>.Drop) {
    guard case let .block(blocks) = drop.lifted.lift, case let .block(index) = drop.target else { return }

    switch drop.lifted.row {
    case let .section(.custom(id)):
      environment.workspaceSections.moveSection(id, toIndex: index)
    case let .group(id):
      commitGroupMove(id, toIndex: index, among: blocks.headers.compactMap(\.groupID))
    default:
      break
    }
  }

  private func commitGroupMove(_ groupID: String, toIndex index: Int, among shownIDs: [String]) {
    let byID = Dictionary(workspaceGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard let key = byID[groupID].map(orderKey) else { return }

    let shown = shownIDs.compactMap { byID[$0].map(orderKey) }
    switch grouping {
    case .machine: machineOrder = SidebarWorkspaceGroup.savedOrder(machineOrder, moving: key, to: index, among: shown)
    case .project: projectOrder = SidebarWorkspaceGroup.savedOrder(projectOrder, moving: key, to: index, among: shown)
    case .flat: break
    }
  }

  private func orderKey(_ group: SidebarWorkspaceGroup) -> String {
    grouping == .project
      ? SidebarWorkspaceGroup.projectKey(group)
      : workspaceListing.machineGroups.group(forServer: group.items[0].serverId).orderKey
  }
}

extension SidebarRowID {
  fileprivate var groupID: String? {
    guard case let .group(id) = self else { return nil }
    return id
  }
}
