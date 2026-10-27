import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  func commitWorkspaceMove(_ sourceID: UUID, toIndex index: Int, within group: [UUID]) {
    let ids = listedSidebarItems.map(\.id)
    let reordered = ListReorder.moving(sourceID, to: index, within: group, in: ids)
    guard reordered != ids,
      let workspace = environment.workspaces.workspace(id: sourceID)
    else { return }
    _ = environment.workspaceSync.reorderWorkspace(
      id: sourceID, visibleIDs: reordered,
      client: environment.machines.client(for: workspace.serverId)
    )
  }
}
