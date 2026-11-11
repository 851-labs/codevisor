import Foundation

enum SharedName {
  static func renameChat(_ sessionId: UUID, to title: String, in records: inout NavigationRecords) {
    if let index = records.sessions.firstIndex(where: { $0.id == sessionId }) {
      records.sessions[index].title = title
    }
    guard let index = records.workspaces.firstIndex(where: { sharedMainSessionId(of: $0) == sessionId })
    else { return }

    records.workspaces[index].name = title
    records.workspaces[index].hasCustomName = true
  }

  static func renameWorkspace(
    _ workspaceId: UUID, to name: String, byHand: Bool, in records: inout NavigationRecords
  ) {
    guard let index = records.workspaces.firstIndex(where: { UUID(uuidString: $0.id) == workspaceId })
    else { return }

    records.workspaces[index].name = name
    records.workspaces[index].hasCustomName = byHand
    guard byHand, let mainId = sharedMainSessionId(of: records.workspaces[index]),
      let chat = records.sessions.firstIndex(where: { $0.id == mainId })
    else { return }

    records.sessions[chat].title = name
  }

  private static func sharedMainSessionId(of workspace: ServerWorkspace) -> UUID? {
    workspace.mainSessionId.flatMap(UUID.init(uuidString:))
  }
}
