import Foundation

/// Everything navigation shows, derived in one place from three inputs: the
/// cached server state of every machine, the outbox's waiting requests laid
/// over it, and this device's own layouts and drafts.
public struct NavigationProjection: Sendable {
  public var projects: [Project] = []
  public var sessions: [ChatSession] = []
  public var workspaces: [Workspace] = []
  public var workspacesById: [UUID: Workspace] = [:]
  /// The workspace each chat belongs to: the server's assignment, or for a
  /// chat the server hasn't placed, the workspace whose layout shows it.
  public var sessionIndex: [UUID: UUID] = [:]
  /// The account's replicated sidebar records (folders and settings): each
  /// machine's copy, waiting writes included, merged by newest revision.
  public var navigationRecords = ServerNavigationRecords()
  /// Each machine's own copy of those records, to find the machines that are
  /// missing a newer one.
  var machineRecords: [String: ServerNavigationRecords] = [:]

  public static let empty = NavigationProjection()
}

/// Maps records into workspaces. `NavigationProjector` decides which ones
/// need mapping; these only build them.
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
    workspace.parentWorkspaceId = record.parentWorkspaceId.flatMap(UUID.init(uuidString:))
    workspace.parentTabPosition = record.parentTabPosition
    workspace.groupCollapsed = record.groupCollapsed ?? false
    workspace.folderId = record.folderId.flatMap(UUID.init(uuidString:))
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
