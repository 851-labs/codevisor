import Foundation

/// How the app reads workspaces and saves this device's layout of them.
/// `ProjectedWorkspaceRepository` is the implementation: workspaces come from
/// the navigation projection, and saves record only tabs and selection.
public protocol WorkspaceRepository: Sendable {
  func loadAll() -> [Workspace]
  func workspace(id: UUID) -> Workspace?
  /// The workspace owning the chat pane for this session, if any.
  func workspaceId(forSession sessionId: UUID) -> UUID?
  /// Saves this device's layout of the workspace (tabs, splits, selection).
  /// Server-owned fields are not saved; they change through the outbox.
  func save(_ workspace: Workspace)
  /// Replaces an automatic workspace name, preserving names explicitly set
  /// by the user.
  func setAutomaticName(_ name: String, forWorkspace workspaceId: UUID)
  func delete(id: UUID)
  func removeAll()
  /// Returns the workspace owning this session's chat, creating a draft
  /// for it on first call.
  func ensureWorkspace(
    for seed: WorkspaceSessionSeed,
    legacyGroups: (any PaneGroupRepository)?
  ) -> Workspace
}

public extension WorkspaceRepository {
  func removeAll() {
    for workspace in loadAll() {
      delete(id: workspace.id)
    }
  }

  /// A stand-in workspace for a chat with no persisted workspace, because
  /// the workspace was deleted out from under it, index entry included.
  /// Shaped exactly like the record `ensureWorkspace` would mint — but NEVER
  /// saved: the still-mounted screen keeps rendering through its teardown
  /// without resurrecting the deleted workspace behind the sidebar's back.
  func ephemeralWorkspace(for seed: WorkspaceSessionSeed) -> Workspace {
    var center = PaneGroupState.centerInitial(sessionId: seed.sessionId)
    for index in center.panes.indices where center.panes[index].kind == .chat {
      if center.panes[index].chatSessionId == nil {
        center.panes[index].chatSessionId = seed.sessionId
      }
    }
    return Workspace(
      name: seed.initialName.isEmpty ? "Workspace" : seed.initialName,
      rootDirectory: seed.rootDirectory,
      worktreeName: seed.worktreeName,
      serverId: seed.serverId,
      projectId: seed.projectId,
      centerTree: .leaf(center)
    )
  }
}

/// Everything the backfill needs to know about a session to give it a
/// workspace. Deliberately a plain bag: Core never sees the app's session
/// types.
public struct WorkspaceSessionSeed: Sendable {
  public let sessionId: UUID
  /// The name to use if this seed creates a workspace. Existing automatic
  /// names only change at explicit context transitions (for example, when a
  /// new worktree finishes creation), not whenever a chat is rendered.
  public let initialName: String
  public let serverId: String
  public let projectId: UUID
  /// The session's working directory (worktree or project folder).
  public let rootDirectory: String?
  /// The session's git worktree, when it lives in one. Stamped onto the
  /// workspace so future sessions inherit it.
  public let worktreeName: String?
  /// The workspace the server says owns this session, when known. A chat
  /// created elsewhere (another client, an agent, the API) arrives with its
  /// membership already decided; honoring it here keeps the chat in that
  /// workspace instead of minting a sibling at the same directory. Nil for
  /// unassigned sessions and for servers that predate workspace ownership.
  public let assignedWorkspaceId: UUID?

  public init(
    sessionId: UUID,
    initialName: String,
    serverId: String,
    projectId: UUID,
    rootDirectory: String?,
    worktreeName: String? = nil,
    assignedWorkspaceId: UUID? = nil
  ) {
    self.sessionId = sessionId
    self.initialName = initialName
    self.serverId = serverId
    self.projectId = projectId
    self.rootDirectory = rootDirectory
    self.worktreeName = worktreeName
    self.assignedWorkspaceId = assignedWorkspaceId
  }
}

/// Persists one workspace leaf through the pane model's storage interface.
public final class WorkspacePaneGroupRepository: PaneGroupRepository, @unchecked Sendable {
  private let workspaceId: UUID
  private let groupId: UUID?
  private let repository: any WorkspaceRepository

  public init(workspaceId: UUID, groupId: UUID?, repository: any WorkspaceRepository) {
    self.workspaceId = workspaceId
    self.groupId = groupId
    self.repository = repository
  }

  /// The session key is deliberately unused: this repository is keyed by
  /// workspace and leaf, so a workspace with no chat persists exactly like one
  /// that has several.
  public func load(sessionId: UUID?) -> PaneGroupState? {
    guard let workspace = repository.workspace(id: workspaceId) else { return nil }
    guard let groupId else { return workspace.centerTree.allGroups.first?.state }
    return workspace.centerTabs.lazy.compactMap { $0.root.group(id: groupId) }.first
  }

  public func save(_ state: PaneGroupState, sessionId: UUID?) {
    guard var workspace = repository.workspace(id: workspaceId) else { return }
    let targetId = groupId ?? workspace.centerTree.allGroups.first?.id
    guard let targetId,
      let tabIndex = workspace.centerTabs.firstIndex(where: {
        $0.root.group(id: targetId) != nil
      })
    else { return }
    workspace.centerTabs[tabIndex].root = workspace.centerTabs[tabIndex].root
      .updatingGroup(id: targetId) { _ in state }
    repository.save(workspace)
  }
}
