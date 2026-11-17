import CodevisorCore
import Foundation

extension SessionStore {
  @discardableResult
  func createWorkspace(
    for session: ChatSession, project: Project, startedBy controller: SessionController
  ) -> Workspace {
    var created = workspace(for: session, project: project, awaitsOwnCheckout: controller.awaitsOwnCheckout)
    created.name = session.worktreeName ?? project.name
    created.hasCustomName = false
    environment.workspaces.save(created)
    return created
  }

  func applyWorktree(_ worktree: ServerWorktree, toWorkspaceOf sessionId: UUID) {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: sessionId) else { return }
    environment.workspaces.setAutomaticName(worktree.name, forWorkspace: workspaceId)
  }
}
