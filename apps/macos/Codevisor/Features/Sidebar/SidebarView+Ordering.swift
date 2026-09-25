import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  /// Saves a finished drag: one move, sent once the header is released.
  /// The rows reflow on screen while the header is dragged, but those steps
  /// only exist in the view -- sending each one would broadcast a workspace
  /// hopping through every slot it passed.
  func commitWorkspaceMove(_ sourceID: UUID, toIndex index: Int) {
    let ids = listedSidebarItems.map(\.id)
    let reordered = ListReorder.moving(sourceID, to: index, in: ids)
    guard reordered != ids,
      let workspace = environment.workspaces.workspace(id: sourceID)
    else { return }
    // The rows already show this order, so the move itself doesn't animate.
    _ = environment.workspaceSync.reorderWorkspace(
      id: sourceID, visibleIDs: reordered,
      client: environment.machines.client(for: workspace.serverId)
    )
  }
}
