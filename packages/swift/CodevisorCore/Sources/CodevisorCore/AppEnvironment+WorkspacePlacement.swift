import Foundation

extension AppEnvironment {
  public func placeWorkspace(_ id: UUID, at placement: SidebarPlacement, among siblings: [UUID], movingSection: Bool) {
    if movingSection { workspaceSections.move(id, to: placement.section) }
    guard siblings.count > 1, let workspace = workspaces.workspace(id: id) else { return }

    workspaceSync.reorderWorkspace(id: id, visibleIDs: siblings, client: machines.client(for: workspace.serverId))
  }
}
