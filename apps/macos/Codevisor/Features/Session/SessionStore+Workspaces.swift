import CodevisorCore
import Foundation

extension SessionStore {
  @discardableResult
  func createWorkspace(for session: ChatSession, project: Project) -> Workspace {
    var created = workspace(for: session, project: project)
    created.name = session.worktreeName ?? project.name
    created.hasCustomName = false
    environment.workspaces.save(created)
    return created
  }

  func applyWorktree(_ worktree: ServerWorktree, toWorkspaceOf sessionId: UUID) {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: sessionId),
      var workspace = environment.workspaces.workspace(id: workspaceId)
    else { return }
    workspace.rootDirectory = worktree.path
    workspace.worktreeName = worktree.name
    environment.workspaces.save(workspace)
    environment.workspaces.setAutomaticName(worktree.name, forWorkspace: workspaceId)
  }
}
