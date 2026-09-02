import CodevisorCore
import Foundation

/// Workspace records created around sent chats. Split from `SessionStore` so
/// the store's class body stays within the size ratchet.
extension SessionStore {
  /// Wraps a just-sent new chat in its workspace: the record is rooted at
  /// the session's directory (the project folder until a first-send
  /// worktree finishes creating — `applyWorktree` moves it then), named
  /// after the project.
  @discardableResult
  func createWorkspace(for session: ChatSession, project: Project) -> Workspace {
    var created = workspace(for: session, project: project)
    created.name = session.worktreeName ?? project.name
    created.hasCustomName = false
    environment.workspaces.save(created)
    return created
  }

  /// The first-send worktree materialized after the workspace was created:
  /// move the workspace onto it — directory, worktree name, and (automatic)
  /// display name.
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
