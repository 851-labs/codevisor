import Foundation

@MainActor
public enum SandboxSessionRelocation {
  public struct Move: Equatable, Sendable {
    public let previous: ChatSession
    public let relocated: ChatSession
  }

  @discardableResult
  public static func relocate(
    _ previous: ChatSession,
    to relocated: ChatSession,
    project: Project,
    projectList: ProjectListModel,
    workspaces: any WorkspaceRepository
  ) -> [Move] {
    projectList.registerServerProject(project)
    projectList.navigationStore?.withdrawExpectedSession(previous.id, machineId: previous.serverId)
    projectList.enqueue(.expectSession(relocated), serverId: relocated.serverId)
    let carried = carryChats(
      of: previous, relocated: relocated, to: project, projectList: projectList, workspaces: workspaces)
    relocateWorkspace(of: previous.id, to: project, in: workspaces)
    return carried
  }

  private static func session(_ session: ChatSession, movedTo project: Project) -> ChatSession {
    var moved = session
    moved.serverId = project.serverId
    moved.projectId = project.id
    moved.harnessId = ""
    moved.cwd = nil
    moved.worktreeName = nil
    return moved
  }

  private static func carryChats(
    of previous: ChatSession,
    relocated: ChatSession,
    to project: Project,
    projectList: ProjectListModel,
    workspaces: any WorkspaceRepository
  ) -> [Move] {
    guard let workspaceId = workspaces.workspaceId(forSession: previous.id),
      let store = projectList.navigationStore
    else { return [] }
    let chats = store.moveDraftWorkspace(workspaceId, from: previous.serverId, to: project) { chat in
      chat.id == previous.id ? relocated : session(chat, movedTo: project)
    }
    return chats.filter { $0.id != previous.id }.map { Move(previous: $0, relocated: session($0, movedTo: project)) }
  }

  public static func relocatedWorkspace(_ workspace: Workspace, to project: Project) -> Workspace {
    var moved = Workspace(
      id: workspace.id,
      name: workspace.name,
      hasCustomName: workspace.hasCustomName,
      rootDirectory: nil,
      serverId: project.serverId,
      projectId: project.id,
      centerTabs: workspace.centerTabs,
      selectedCenterTabId: workspace.selectedCenterTabId,
      createdAt: workspace.createdAt,
      isArchived: workspace.isArchived
    )
    moved.sidebarPosition = workspace.sidebarPosition
    return moved
  }

  private static func relocateWorkspace(
    of sessionId: UUID,
    to project: Project,
    in workspaces: any WorkspaceRepository
  ) {
    guard let workspaceId = workspaces.workspaceId(forSession: sessionId),
      let workspace = workspaces.workspace(id: workspaceId)
    else { return }
    workspaces.delete(id: workspaceId)
    workspaces.save(relocatedWorkspace(workspace, to: project))
  }
}
