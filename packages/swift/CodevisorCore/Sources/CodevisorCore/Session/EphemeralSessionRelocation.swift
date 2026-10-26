import Foundation

@MainActor
public enum EphemeralSessionRelocation {
  public static func relocate(
    _ previous: ChatSession,
    to relocated: ChatSession,
    project: Project,
    projectList: ProjectListModel,
    workspaces: any WorkspaceRepository
  ) {
    projectList.registerServerProject(project)
    projectList.navigationStore?.withdrawExpectedSession(previous.id, machineId: previous.serverId)
    projectList.enqueue(.expectSession(relocated), serverId: relocated.serverId)
    relocateWorkspace(of: previous.id, to: project, in: workspaces)
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
