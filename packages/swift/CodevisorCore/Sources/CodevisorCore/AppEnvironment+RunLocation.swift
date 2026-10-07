import Foundation

extension AppEnvironment {
  /// Whether a new chat in `project` should start in a fresh git worktree.
  ///
  /// The project's own choice wins: it is stored on every machine holding
  /// the repository, so each client and machine restores the same one.
  /// This client's local memory covers projects whose servers predate that
  /// field (or that no composer has chosen for yet).
  public func prefersNewWorktree(for project: Project) -> Bool {
    guard project.isGitRepository else { return false }
    let shared =
      projectList.fleetProjectGroup(containing: project)?.defaultRunLocation
      ?? project.defaultRunLocation
    if let shared { return shared.isNewWorktree }
    return composerDefaults.prefersWorktreeForNewWorkspaces(
      forServer: project.serverId,
      projectId: project.id
    )
  }

  /// Records an explicit run-location pick for the whole project — every
  /// machine that has it and, through them, every client.
  public func rememberRunLocation(newWorktree: Bool, for project: Project) {
    composerDefaults.rememberNewWorkspaceWorktreePreference(
      serverId: project.serverId,
      projectId: project.id,
      createsWorktree: newWorktree
    )
    projectList.setDefaultRunLocation(
      ProjectRunLocation(newWorktree: newWorktree),
      for: projectList.fleetProjectGroup(containing: project) ?? ProjectGroup(solo: project)
    )
  }

  /// Records the run location a first send used. A project nobody has
  /// chosen one for yet shares it, so a choice this client remembered
  /// locally (before choices were shared) reaches the other clients. An
  /// existing shared choice is left alone: only an explicit pick changes it.
  public func rememberSentRunLocation(newWorktree: Bool, for project: Project) {
    composerDefaults.rememberNewWorkspaceWorktreePreference(
      serverId: project.serverId,
      projectId: project.id,
      createsWorktree: newWorktree
    )
    let group = projectList.fleetProjectGroup(containing: project) ?? ProjectGroup(solo: project)
    guard group.defaultRunLocation == nil else { return }
    projectList.setDefaultRunLocation(ProjectRunLocation(newWorktree: newWorktree), for: group)
  }
}
