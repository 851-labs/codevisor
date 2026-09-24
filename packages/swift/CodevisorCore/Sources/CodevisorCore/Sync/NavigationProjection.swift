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

  public static let empty = NavigationProjection()
}

enum NavigationProjectionBuilder {
  struct Result {
    var projection: NavigationProjection
    /// Layouts that changed while fitting them to the server's panes. They
    /// are saved back so tab identities stay stable between rebuilds.
    var reconciledLayouts: [UUID: DeviceLayout]
  }

  static func build(
    records: [(machineId: String, records: NavigationRecords)],
    layouts: DeviceLayoutStore
  ) -> Result {
    var projection = NavigationProjection()
    var reconciled: [UUID: DeviceLayout] = [:]
    var serverWorkspaceIds = Set<UUID>()
    for (machineId, machine) in records {
      projection.projects += machine.projects
      projection.sessions += machine.sessions
      let panesByWorkspace = Dictionary(grouping: machine.panes) { $0.workspaceId.lowercased() }
      for record in machine.workspaces {
        guard let workspace = workspace(from: record, machineId: machineId, machine: machine) else { continue }
        serverWorkspaceIds.insert(workspace.id)
        let stored = layouts.layout(for: workspace.id)
        var fitted = workspace
        if let stored {
          fitted.centerTabs = stored.tabs.isEmpty ? [WorkspaceTab.placeholder()] : stored.tabs
          fitted.selectedCenterTabId = stored.selectedTabId
        }
        WorkspaceSyncModel.reconcilePanes(
          in: &fitted, records: panesByWorkspace[record.id.lowercased()] ?? [], protectedLocalPaneIds: [])
        let layout = DeviceLayout(fitted)
        if layout != stored { reconciled[fitted.id] = layout }
        insert(fitted, into: &projection)
      }
      for (sessionId, workspaceId) in machine.assignments { projection.sessionIndex[sessionId] = workspaceId }
    }
    for draft in layouts.drafts where !serverWorkspaceIds.contains(draft.id) {
      guard let layout = layouts.layout(for: draft.id), !layout.tabs.isEmpty else { continue }
      insert(workspace(from: draft, layout: layout), into: &projection)
    }
    // A chat the server hasn't placed in a workspace belongs to the one
    // whose layout shows it -- typically the draft its first message creates.
    for workspace in projection.workspaces {
      for sessionId in workspace.chatSessionIds where projection.sessionIndex[sessionId] == nil {
        projection.sessionIndex[sessionId] = workspace.id
      }
    }
    projection.workspaces.sort {
      ($0.serverId, $0.createdAt, $0.id.uuidString) < ($1.serverId, $1.createdAt, $1.id.uuidString)
    }
    return Result(projection: projection, reconciledLayouts: reconciled)
  }

  private static func insert(_ workspace: Workspace, into projection: inout NavigationProjection) {
    projection.workspaces.append(workspace)
    projection.workspacesById[workspace.id] = workspace
  }

  static func workspace(
    from record: ServerWorkspace, machineId: String, machine: NavigationRecords
  ) -> Workspace? {
    guard let id = UUID(uuidString: record.id), let projectId = UUID(uuidString: record.projectId),
      let createdAt = try? ServerDateCoding.date(from: record.createdAt)
    else {
      Log.sync.error("Dropping unmappable server workspace \(record.id, privacy: .public)")
      return nil
    }
    // Chats in a worktree workspace all run in the same worktree, so any of
    // them names it for new chats started there.
    let worktreeName = machine.sessions.lazy
      .filter { machine.assignments[$0.id] == id }
      .compactMap(\.worktreeName).first
    let placeholder = WorkspaceTab.placeholder()
    var workspace = Workspace(
      id: id, name: record.name, hasCustomName: record.hasCustomName, rootDirectory: record.rootDirectory,
      worktreeName: worktreeName, serverId: machineId, projectId: projectId, centerTabs: [placeholder],
      createdAt: createdAt, isArchived: record.isArchived, isServerSynced: true)
    workspace.sidebarPosition = record.sidebarPosition
    workspace.sidebarOrderRevision = record.sidebarOrderRevision ?? 0
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
