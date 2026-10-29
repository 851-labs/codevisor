import Foundation

public protocol WorkspaceRepository: Sendable {
  func loadAll() -> [Workspace]
  func workspace(id: UUID) -> Workspace?
  func workspaceId(forSession sessionId: UUID) -> UUID?
  func save(_ workspace: Workspace)
  func setAutomaticName(_ name: String, forWorkspace workspaceId: UUID)
  func delete(id: UUID)
  func removeAll()
  func ensureWorkspace(
    for seed: WorkspaceSessionSeed,
    legacyGroups: (any PaneGroupRepository)?
  ) -> Workspace
}

public extension WorkspaceRepository {
  func mainFirstChatSessionIds(in workspace: Workspace) -> [UUID] {
    workspace.mainFirstChatSessionIds.filter { workspaceId(forSession: $0) == workspace.id }
  }

  func isSideChat(_ sessionId: UUID) -> Bool {
    guard let workspaceId = workspaceId(forSession: sessionId),
      let mainSessionId = workspace(id: workspaceId)?.mainSessionId
    else { return false }
    return mainSessionId != sessionId
  }

  func removeAll() {
    for workspace in loadAll() {
      delete(id: workspace.id)
    }
  }

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

public struct WorkspaceSessionSeed: Sendable {
  public let sessionId: UUID
  public let initialName: String
  public let serverId: String
  public let projectId: UUID
  public let rootDirectory: String?
  public let worktreeName: String?
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

public final class WorkspacePaneGroupRepository: PaneGroupRepository, @unchecked Sendable {
  private let workspaceId: UUID
  private let groupId: UUID?
  private let repository: any WorkspaceRepository

  public init(workspaceId: UUID, groupId: UUID?, repository: any WorkspaceRepository) {
    self.workspaceId = workspaceId
    self.groupId = groupId
    self.repository = repository
  }

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
