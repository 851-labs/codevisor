import Foundation

/// This device's copy of one machine's navigation state, exactly as the
/// server last described it, plus the same records mapped into app types.
///
/// Nothing on the device edits it. It is replaced by a full snapshot when the
/// machine connects and moved forward only by that machine's own events, so it
/// is always a state the server was really in.
struct MachineNavigationCache: Sendable {
  let machineId: String
  let snapshot: ServerNavigationSnapshot
  let projects: [Project]
  let sessions: [ChatSession]
  /// Which workspace the server says each chat belongs to.
  let assignments: [UUID: UUID]

  var eventCursor: Int { snapshot.eventCursor }

  var isEmpty: Bool { snapshot.workspaces.isEmpty && snapshot.sessions.isEmpty }

  init(machineId: String, snapshot: ServerNavigationSnapshot) {
    self.machineId = machineId
    self.snapshot = snapshot
    var projects: [Project] = []
    for record in snapshot.projects {
      do {
        projects.append(try record.project(serverId: machineId))
      } catch {
        Log.sync.error("Dropping server project \(record.id, privacy: .public) that failed to map")
      }
    }
    var sessions: [ChatSession] = []
    var assignments: [UUID: UUID] = [:]
    for record in snapshot.sessions {
      do {
        let session = try record.chatSession(serverId: machineId)
        sessions.append(session)
        if let workspaceId = record.workspaceId.flatMap(UUID.init(uuidString:)) {
          assignments[session.id] = workspaceId
        }
      } catch {
        Log.sync.error("Dropping server session \(record.id, privacy: .public) that failed to map")
      }
    }
    self.projects = projects
    self.sessions = sessions
    self.assignments = assignments
  }

  /// Mapping a large snapshot is kept off the main actor.
  static func build(machineId: String, snapshot: ServerNavigationSnapshot) async -> MachineNavigationCache {
    await Task.detached(priority: .userInitiated) {
      MachineNavigationCache(machineId: machineId, snapshot: snapshot)
    }.value
  }

  /// The cache moved forward by one of the machine's events, or nil when the
  /// event is not newer than what the cache already has.
  func applying(_ delta: ServerNavigationDelta) async -> MachineNavigationCache? {
    guard delta.eventCursor > snapshot.eventCursor else { return nil }
    return await Self.build(machineId: machineId, snapshot: delta.applying(to: snapshot))
  }
}
