import Foundation

struct UpdateAllPlan: Sendable {
  struct Machine: Sendable {
    let machineId: String
    let harnesses: [UpdateComponent]
    let server: UpdateComponent?
    let app: UpdateComponent?

    var harnessIds: [String] { harnesses.map(\.subjectId) }

    var componentIds: [String] {
      harnesses.map(\.id) + [server?.id, app?.id].compactMap { $0 }
    }
  }

  let machines: [Machine]

  init(_ snapshot: [UpdateComponent]) {
    let machineIds = Self.orderedMachineIds(snapshot)
    machines = machineIds.map { machineId in
      let rows = snapshot.filter { $0.machineId == machineId }
      return Machine(
        machineId: machineId,
        harnesses: rows.filter { $0.kind == .harness },
        server: rows.first { $0.kind == .server },
        app: rows.first { $0.kind == .app }
      )
    }
  }

  var includesApp: Bool { machines.contains { $0.app != nil } }

  private static func orderedMachineIds(_ rows: [UpdateComponent]) -> [String] {
    var seen: [String] = []
    for row in rows where !seen.contains(row.machineId) { seen.append(row.machineId) }
    let appMachines = Set(rows.filter { $0.kind == .app }.map(\.machineId))
    return seen.filter { !appMachines.contains($0) } + seen.filter { appMachines.contains($0) }
  }
}
