import Foundation
@testable import CodevisorCore

extension WorkspaceSyncModel {
  /// The record a machine holds for this workspace, as its navigation
  /// snapshot and deltas carry it.
  nonisolated static func serverWorkspace(from workspace: Workspace) -> ServerWorkspace {
    ServerWorkspace(
      id: workspace.id.uuidString,
      serverId: workspace.serverId,
      projectId: workspace.projectId.uuidString,
      name: workspace.name,
      hasCustomName: workspace.hasCustomName,
      rootDirectory: workspace.rootDirectory,
      isArchived: workspace.isArchived,
      createdAt: ServerDateCoding.string(from: workspace.createdAt),
      sidebarPosition: workspace.sidebarPosition,
      sidebarOrderRevision: workspace.sidebarOrderRevision > 0 ? workspace.sidebarOrderRevision : nil
    )
  }
}
