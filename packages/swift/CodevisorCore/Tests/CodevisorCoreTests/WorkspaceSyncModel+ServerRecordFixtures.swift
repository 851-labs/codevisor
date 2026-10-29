import Foundation
@testable import CodevisorCore

extension WorkspaceSyncModel {
  nonisolated static func serverWorkspace(from workspace: Workspace) -> ServerWorkspace {
    ServerWorkspace(
      id: workspace.id.uuidString,
      serverId: workspace.serverId,
      projectId: workspace.projectId.uuidString,
      name: workspace.name,
      hasCustomName: workspace.hasCustomName,
      rootDirectory: workspace.rootDirectory,
      isArchived: workspace.isArchived,
      archivedAt: workspace.archivedAt.map(ServerDateCoding.string(from:)),
      createdAt: ServerDateCoding.string(from: workspace.createdAt),
      sidebarPosition: workspace.sidebarPosition,
      sidebarOrderRevision: workspace.sidebarOrderRevision > 0 ? workspace.sidebarOrderRevision : nil,
      git: workspace.git,
      botId: workspace.botId?.uuidString,
      botMachineId: workspace.botMachineId,
      mainSessionId: workspace.mainSessionId?.uuidString
    )
  }
}
