import Foundation

@testable import CodevisorCore

extension ProjectListModel {
  /// Puts a machine's server records in place the way its snapshot does, for
  /// machine tests that only hold the project list a controller renders.
  /// The app can't assign `projects`/`sessions` either: they come from the
  /// navigation store.
  func installServerRecords(
    machineId: String,
    projects: [Project] = [],
    sessions: [ChatSession] = [],
    cursor: Int = 1
  ) async {
    guard let navigationStore else {
      preconditionFailure("installServerRecords needs a ProjectListModel.fixture()")
    }
    await navigationStore.replace(
      .fixture(projects: projects, sessions: sessions, cursor: cursor),
      machineId: machineId, requestedAt: Date())
  }

  /// A project with one chat installed under `machineId`.
  @discardableResult
  func installProjectWithChat(machineId: String, folder: String, title: String = "chat") async -> Project {
    let project = Project.fromFolder(URL(fileURLWithPath: folder), serverId: machineId)
    let session = ChatSession(projectId: project.id, serverId: machineId, title: title)
    await installServerRecords(machineId: machineId, projects: [project], sessions: [session])
    return project
  }
}
