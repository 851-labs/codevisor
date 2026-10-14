import Foundation

@testable import CodevisorCore

extension ProjectListModel {
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

  @discardableResult
  func installProjectWithChat(machineId: String, folder: String, title: String = "chat") async -> Project {
    let project = Project.fromFolder(URL(fileURLWithPath: folder), serverId: machineId)
    let session = ChatSession(projectId: project.id, serverId: machineId, title: title)
    await installServerRecords(machineId: machineId, projects: [project], sessions: [session])
    return project
  }
}
