import Foundation

extension ProjectListModel {
  private static let fractionalImportTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let wholeSecondImportTimestampFormatter = ISO8601DateFormatter()

  public func importSessions(_ imported: [ImportedSession], serverId: String) {
    for item in imported {
      if let known = sessions.first(where: {
        $0.serverId == serverId
          && $0.harnessId == item.harnessId
          && $0.agentSessionId == item.info.sessionId
      }) {
        reconcileImportedActivity(item, of: known)
        continue
      }
      let project = findOrCreateProject(
        folderURL: URL(fileURLWithPath: item.info.cwd),
        serverId: serverId
      )
      let timestamp = Self.importTimestamp(item.info.updatedAt)
      importSession(
        ChatSession(
          projectId: project.id,
          serverId: serverId,
          harnessId: item.harnessId,
          agentSessionId: item.info.sessionId,
          title: item.info.title ?? "Session",
          origin: .imported,
          createdAt: timestamp ?? Date(),
          updatedAt: timestamp
        ))
    }
  }

  public func importSessions(_ imported: [ImportedSession], into project: Project) {
    for item in imported {
      if let known = sessions.first(where: {
        $0.serverId == project.serverId
          && $0.harnessId == item.harnessId
          && $0.agentSessionId == item.info.sessionId
      }) {
        reconcileImportedActivity(item, of: known)
        continue
      }
      let timestamp = Self.importTimestamp(item.info.updatedAt)
      importSession(
        ChatSession(
          projectId: project.id,
          serverId: project.serverId,
          harnessId: item.harnessId,
          agentSessionId: item.info.sessionId,
          title: item.info.title ?? "Session",
          origin: .imported,
          createdAt: timestamp ?? Date(),
          updatedAt: timestamp
        ))
    }
  }

  private func importSession(_ session: ChatSession) {
    enqueue(.upsertSession(session, workspaceId: nil), serverId: session.serverId)
  }

  private func reconcileImportedActivity(_ item: ImportedSession, of known: ChatSession) {
    guard let discoveredAt = Self.importTimestamp(item.info.updatedAt),
      discoveredAt > known.updatedAt ?? known.createdAt
    else { return }
    var updated = known
    updated.updatedAt = discoveredAt
    importSession(updated)
  }

  private static func importTimestamp(_ value: String?) -> Date? {
    guard let value else { return nil }
    return fractionalImportTimestampFormatter.date(from: value)
      ?? wholeSecondImportTimestampFormatter.date(from: value)
  }

  private func findOrCreateProject(folderURL: URL, serverId: String) -> Project {
    if let existing = projects.first(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
      return existing
    }
    let project = Project.fromFolder(folderURL, serverId: serverId, origin: .imported)
    enqueue(.upsertProject(project), serverId: serverId)
    return project
  }
}
