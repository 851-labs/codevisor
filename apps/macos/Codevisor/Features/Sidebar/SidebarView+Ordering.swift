import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  /// Applies a live reorder while a header is dragged. Each call persists
  /// optimistically; the sync model coalesces the server writes.
  func moveWorkspace(_ sourceID: UUID, toIndex index: Int) {
    let ids = visibleSidebarItems.map(\.id)
    let reordered = ListReorder.moving(sourceID, to: index, in: ids)
    guard reordered != ids,
      let workspace = environment.workspaces.workspace(id: sourceID)
    else { return }
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
      // The write is fire-and-forget; the sync model coalesces and owns it.
      _ = environment.workspaceSync.reorderWorkspace(
        id: sourceID, visibleIDs: reordered,
        client: environment.machines.client(for: workspace.serverId)
      )
    }
  }
}
