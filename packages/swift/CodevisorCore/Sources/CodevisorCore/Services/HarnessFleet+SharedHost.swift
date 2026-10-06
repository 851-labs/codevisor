import Foundation

/// A fleet-shared sign-in still has to run on some machine. Finding one used
/// to mean asking every machine in turn and waiting for each answer; this
/// asks the likely candidates at once and takes the first that has the
/// harness ready.
public extension HarnessFleet {
  struct SharedHost: Equatable, Sendable {
    public var machineId: String
    public var harness: ServerHarness

    public init(machineId: String, harness: ServerHarness) {
      self.machineId = machineId
      self.harness = harness
    }
  }

  /// Reachable machines, most promising first: the caller's preferred
  /// machine (the chat's, the selected one), then this machine, which
  /// answers without a network hop, then machines whose report says the
  /// harness is installed, then machines with no report yet. Hosting only
  /// needs the harness installed: a machine that is signed out is as good
  /// a host as a ready one. A machine reporting it doesn't have the harness
  /// is never asked.
  nonisolated static func sharedHostCandidates(
    harnessId: String, machines: [FleetMachine], readiness: [String: [MachineReadiness]], preferred: String?
  ) -> [String] {
    func report(_ machine: FleetMachine) -> MachineReadiness? {
      machine.syncKey.flatMap { readiness[$0]?.first { $0.harnessId == harnessId } }
    }
    func installed(_ row: MachineReadiness) -> Bool {
      row.installed ?? !["notInstalled", "disabled"].contains(row.state)
    }
    let reachable = machines.filter { machine in
      machine.isReachable && report(machine).map(installed) != false
    }
    let rank = { (machine: FleetMachine) -> Int in
      if machine.id == preferred { return 0 }
      if machine.isLocal { return 1 }
      return report(machine) == nil ? 3 : 2
    }
    // Sorting is stable, so machines of equal rank keep their list order.
    return reachable.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element.id)
  }

  /// One online machine that has the harness ready, or nil when none does.
  static func findSharedHost(
    harnessId: String, preferred: String? = nil, environment: AppEnvironment
  ) async -> SharedHost? {
    let candidates = sharedHostCandidates(
      harnessId: harnessId, machines: fleetMachines(environment.machines),
      readiness: readiness(environment.configSync), preferred: preferred)
    guard !candidates.isEmpty else { return nil }
    return await withTaskGroup(of: (Int, ServerHarness?).self) { group in
      for (index, machineId) in candidates.enumerated() {
        let client = environment.machines.client(for: machineId)
        group.addTask {
          let harness = try? await client.listHarnesses().first { $0.id == harnessId }
          return (index, harness?.isReady == true ? harness : nil)
        }
      }
      // Machines answer in any order; keep the best-ranked hit but stop as
      // soon as the top-ranked candidate reports, or the first hit lands
      // and nothing better is still pending.
      var best: (Int, ServerHarness)?
      var pending = Set(candidates.indices)
      for await (index, harness) in group {
        pending.remove(index)
        if let harness, best == nil || index < best!.0 { best = (index, harness) }
        if let best, pending.allSatisfy({ $0 > best.0 }) {
          group.cancelAll()
          return SharedHost(machineId: candidates[best.0], harness: best.1)
        }
      }
      return best.map { SharedHost(machineId: candidates[$0.0], harness: $0.1) }
    }
  }
}
