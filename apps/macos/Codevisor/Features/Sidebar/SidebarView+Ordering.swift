import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  /// Saves a finished workspace drag: one move, sent once the row is
  /// released. The rows hold still during the drag, so this is the only
  /// change anyone sees.
  ///
  /// A drag reorders within its group (`index` is a position in `group`);
  /// the group's new order fills the slots its members held in the shared
  /// order, so workspaces in other groups keep their places.
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
