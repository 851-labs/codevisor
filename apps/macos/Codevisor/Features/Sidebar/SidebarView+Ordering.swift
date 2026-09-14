import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  func moveWorkspace(_ sourceID: UUID, to destinationID: UUID) {
    var ids = workspaceItems.map(\.workspace.id)
    guard sourceID != destinationID,
      let source = ids.firstIndex(of: sourceID),
      let destination = ids.firstIndex(of: destinationID),
      let workspace = environment.workspaces.workspace(id: sourceID)
    else { return }
    ids.remove(at: source)
    ids.insert(sourceID, at: destination)
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
      environment.workspaceSync.reorderWorkspace(
        id: sourceID, visibleIDs: ids,
        client: environment.machines.client(for: workspace.serverId)
      )
    }
  }
}
