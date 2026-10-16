import Foundation

public struct NavigationProjection: Sendable {
  public var projects: [Project] = []
  public var sessions: [ChatSession] = []
  public var workspaces: [Workspace] = []
  public var workspacesById: [UUID: Workspace] = [:]
  public var sessionIndex: [UUID: UUID] = [:]

  public static let empty = NavigationProjection()
}

enum NavigationProjectionBuilder {
  static func workspace(
    from record: ServerWorkspace, machineId: String, worktreeName: String?
  ) -> Workspace? {
    guard let id = UUID(uuidString: record.id), let projectId = UUID(uuidString: record.projectId),
      let createdAt = try? ServerDateCoding.date(from: record.createdAt)
    else {
      Log.sync.error("Dropping unmappable server workspace \(record.id, privacy: .public)")
      return nil
    }
    let placeholder = WorkspaceTab.placeholder()
    var workspace = Workspace(
      id: id, name: record.name, hasCustomName: record.hasCustomName, rootDirectory: record.rootDirectory,
      worktreeName: worktreeName, serverId: machineId, projectId: projectId, centerTabs: [placeholder],
      createdAt: createdAt, isArchived: record.isArchived, isServerSynced: true)
    workspace.sidebarPosition = record.sidebarPosition
    workspace.sidebarOrderRevision = record.sidebarOrderRevision ?? 0
    workspace.git = record.git
    workspace.botId = record.botId.flatMap(UUID.init(uuidString:))
    return workspace
  }

  static func workspace(from draft: WorkspaceDraft, layout: DeviceLayout) -> Workspace {
    var workspace = Workspace(
      id: draft.id, name: draft.name, rootDirectory: draft.rootDirectory, worktreeName: draft.worktreeName,
      serverId: draft.serverId, projectId: draft.projectId, centerTabs: layout.tabs,
      selectedCenterTabId: layout.selectedTabId, createdAt: draft.createdAt, isServerSynced: false,
      sidebarOrderHead: nil)
    workspace.sidebarPosition = draft.sidebarPosition ?? workspace.sidebarPosition
    return workspace
  }
}
