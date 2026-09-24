import Foundation

extension ProjectListModel {
  /// Whether this project is being deleted from under a surface that is
  /// still showing it. Reads the waiting delete rather than "absent from
  /// `projects`", which a machine going quiet must not be mistaken for.
  public func isProjectDeleted(id: UUID, serverId: String) -> Bool {
    navigationStore?.pendingIntents.contains { entry in
      guard entry.machineId == serverId, case let .deleteProject(projectId, _) = entry.intent else { return false }
      return projectId == id
    } ?? false
  }

  /// Adds a project for a folder, reusing an existing entry if the folder
  /// is already present.
  @discardableResult
  public func addProject(folderURL: URL) -> Project {
    addProject(folderURL: folderURL, serverId: selectedServerId)
  }

  /// Adds a project for an explicit machine. App flows use this entry point
  /// so a composer default cannot redirect persistence or server writes.
  @discardableResult
  public func addProject(folderURL: URL, serverId: String) -> Project {
    if let existing = projects.first(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
      return existing
    }
    let project = Project.fromFolder(folderURL, serverId: serverId)
    enqueue(.upsertProject(project), serverId: serverId)
    return project
  }

  /// Shows a project the server already owns (a fresh clone-from-git) under
  /// the server's project id until its snapshot lists it.
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

  /// Shows a project the server just created on this client's behalf (a
  /// scratch backing project), exactly as the server described it.
  public func registerServerProject(_ project: Project) {
    enqueue(.upsertProject(project), serverId: project.serverId)
  }

  /// Deletes a project and every chat in it.
  public func removeProject(_ project: Project) {
    let sessionIds = sessions.filter { $0.serverId == project.serverId && $0.projectId == project.id }.map(\.id)
    enqueue(.deleteProject(projectId: project.id, sessionIds: sessionIds), serverId: project.serverId)
  }
}
