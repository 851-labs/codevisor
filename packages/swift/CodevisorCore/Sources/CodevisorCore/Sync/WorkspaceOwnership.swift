import CodevisorClient
import Foundation

@MainActor
final class WorkspaceOwnership {
  private var key: [String: UInt64?] = [:]
  private var yielded: [String: Set<UUID>] = [:]

  func yieldedWorkspaces(
    machineIds: [String],
    cache: (String) -> MachineNavigationCache?,
    cacheGeneration: (String) -> UInt64?
  ) -> [String: Set<UUID>] {
    let current = Dictionary(uniqueKeysWithValues: machineIds.map { ($0, cacheGeneration($0)) })
    if current == key { return yielded }
    key = current
    yielded = Self.yielded(machineIds.map { ($0, cache($0)?.snapshot.workspaces ?? []) })
    return yielded
  }

  nonisolated static func yielded(
    _ listings: [(machineId: String, workspaces: [ServerWorkspace])]
  ) -> [String: Set<UUID>] {
    var owners: [String: (machineId: String, createdAt: String)] = [:]
    var yielded: [String: Set<UUID>] = [:]
    for (machineId, workspaces) in listings {
      for workspace in workspaces {
        let id = workspace.id.lowercased()
        guard let owner = owners[id] else {
          owners[id] = (machineId, workspace.createdAt)
          continue
        }
        let loser = isNewer(owner.createdAt, than: workspace.createdAt) ? machineId : owner.machineId
        if loser == owner.machineId { owners[id] = (machineId, workspace.createdAt) }
        if let uuid = UUID(uuidString: workspace.id) { yielded[loser, default: []].insert(uuid) }
      }
    }
    return yielded
  }

  private nonisolated static func isNewer(_ left: String, than right: String) -> Bool {
    guard let leftDate = try? ServerDateCoding.date(from: left), let rightDate = try? ServerDateCoding.date(from: right)
    else { return false }
    return leftDate > rightDate
  }
}

extension NavigationRecords {
  mutating func yield(_ workspaceIds: Set<UUID>) {
    guard !workspaceIds.isEmpty else { return }
    let yieldedSessions = Set(assignments.filter { workspaceIds.contains($0.value) }.keys)
    workspaces.removeAll { UUID(uuidString: $0.id).map(workspaceIds.contains) ?? false }
    panes.removeAll { UUID(uuidString: $0.workspaceId).map(workspaceIds.contains) ?? false }
    sessions.removeAll { yieldedSessions.contains($0.id) }
    assignments = assignments.filter { !workspaceIds.contains($0.value) }
  }
}
