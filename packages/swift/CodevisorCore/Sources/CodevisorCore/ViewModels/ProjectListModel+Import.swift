import Foundation

extension ProjectListModel {
  /// Shared: formatter construction is milliseconds-expensive and the
  /// import loops used to build one per imported session. Native scanners
  /// emit JavaScript ISO strings with fractional seconds; legacy servers may
  /// still return whole-second timestamps, so accept both forms.
  private static let fractionalImportTimestampFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  private static let wholeSecondImportTimestampFormatter = ISO8601DateFormatter()

  /// Imports sessions discovered from harnesses, creating projects by cwd and
  /// skipping any already known (by harness + agent session id).
  ///
  /// `serverId` is the machine the sessions were discovered on, snapshotted
  /// by the caller BEFORE the async discovery ran. Discovery is a network
  /// round-trip; tagging results with the live `selectedServerId` here would
  /// file another machine's sessions (and their projects) under whichever
  /// machine the user has switched to meanwhile.
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

  /// Imports sessions into a specific project (they were discovered for its
  /// folder), merging newer activity into known harness-session records.
  /// Sessions inherit the project's server, not the currently selected one:
  /// the user may confirm a pending import after switching machines.
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

  /// Native-session discovery is also our source of truth for activity that
  /// happened outside this app. Never roll a cached/server timestamp back,
  /// and leave user-edited metadata (especially the title) alone.
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

  /// Finds a project by folder, or creates one (without changing archive
  /// state). Used by the importer so it doesn't un-archive existing folders.
  private func findOrCreateProject(folderURL: URL, serverId: String) -> Project {
    if let existing = projects.first(where: { $0.serverId == serverId && $0.folderURL == folderURL }) {
      return existing
    }
    let project = Project.fromFolder(folderURL, serverId: serverId, origin: .imported)
    enqueue(.upsertProject(project), serverId: serverId)
    return project
  }
}
