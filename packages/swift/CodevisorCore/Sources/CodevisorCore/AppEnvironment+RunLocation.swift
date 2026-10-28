import Foundation

extension AppEnvironment {
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

  public func prefersNewWorktree(for group: ProjectGroup) -> Bool {
    if let shared = group.defaultRunLocation { return shared.isNewWorktree }
    return group.members.contains { prefersNewWorktree(for: $0) }
  }

  public func rememberRunLocation(newWorktree: Bool, for group: ProjectGroup) {
    projectList.setDefaultRunLocation(ProjectRunLocation(newWorktree: newWorktree), for: group)
  }

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
