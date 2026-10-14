import Foundation

struct MachineNavigationCache: Sendable {
  let machineId: String
  let snapshot: ServerNavigationSnapshot
  let projects: [Project]
  let sessions: [ChatSession]
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

  static func build(machineId: String, snapshot: ServerNavigationSnapshot) async -> MachineNavigationCache {
    await Task.detached(priority: .userInitiated) {
      MachineNavigationCache(machineId: machineId, snapshot: snapshot)
    }.value
  }

  func applying(_ delta: ServerNavigationDelta) async -> MachineNavigationCache? {
    guard delta.eventCursor > snapshot.eventCursor else { return nil }
    return await Self.build(machineId: machineId, snapshot: delta.applying(to: snapshot))
  }
}
