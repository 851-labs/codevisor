import Foundation

extension ProjectListModel {
  public func isProjectDeleted(id: UUID, serverId: String) -> Bool {
    navigationStore?.pendingIntents.contains { entry in
      guard entry.machineId == serverId, case let .deleteProject(projectId, _, _) = entry.intent else { return false }
      return projectId == id
    } ?? false
  }

  public func registeredFolderPaths(serverId: String) -> Set<String> {
    Set(
      fleetActiveProjects
        .filter { $0.serverId == serverId && !$0.isScratch }
        .map { $0.folderURL.standardizedFileURL.path }
    )
  }

  @discardableResult
  public func addProject(folderURL: URL) -> Project {
    addProject(folderURL: folderURL, serverId: selectedServerId)
  }

  @discardableResult
  public func addProject(folderURL: URL, serverId: String) -> Project {
    if let existing = projects.first(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
      return existing
    }
    let project = Project.fromFolder(folderURL, serverId: serverId)
    enqueue(.upsertProject(project), serverId: serverId)
    return project
  }

  @discardableResult
  public func adoptServerProject(
    id: UUID, folderURL: URL, name: String, serverId: String? = nil
  ) -> Project {
    let server = serverId ?? selectedServerId
    if let existing = projects.first(where: { $0.serverId == server && $0.id == id }) { return existing }
    var project = Project.fromFolder(folderURL, serverId: server)
    project.id = id
    project.name = name
    project.locations = project.locations.map { location in
      var updated = location
      updated.projectId = id
      return updated
    }
    enqueue(.upsertProject(project), serverId: server)
    return project
  }

  public func registerServerProject(_ project: Project) {
    enqueue(.upsertProject(project), serverId: project.serverId)
  }

  public func removeProject(_ project: Project, deletingFiles: Bool = false) {
    let sessionIds = sessions.filter { $0.serverId == project.serverId && $0.projectId == project.id }.map(\.id)
    enqueue(
      .deleteProject(projectId: project.id, sessionIds: sessionIds, deletesFiles: deletingFiles ? true : nil),
      serverId: project.serverId)
  }

  public func removeProjectGroup(_ group: ProjectGroup, deletingFiles: Bool = false) {
    for project in group.members { removeProject(project, deletingFiles: deletingFiles) }
  }

  public func setWorktreeBase(_ base: ProjectWorktreeBase, for group: ProjectGroup) {
    for project in group.members where project.isGitRepository && project.worktreeBase != base {
      enqueue(.setProjectWorktreeBase(projectId: project.id, worktreeBase: base), serverId: project.serverId)
    }
  }

  public func setDefaultRunLocation(_ location: ProjectRunLocation, for group: ProjectGroup) {
    for project in group.members where project.isGitRepository && project.defaultRunLocation != location {
      enqueue(
        .setProjectDefaultRunLocation(projectId: project.id, location: location),
        serverId: project.serverId
      )
    }
  }

  public func alignWorktreeBase(for group: ProjectGroup) {
    let chosen = group.members.filter(\.isGitRepository).contains { $0.worktreeBase != nil }
    guard chosen else { return }
    setWorktreeBase(group.worktreeBase, for: group)
  }
}
