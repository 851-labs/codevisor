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
  /// machine (the chat's, the selected one), then machines whose readiness
  /// report says the harness is ready there, then the rest.
  nonisolated static func sharedHostCandidates(
    harnessId: String, machines: [FleetMachine], readiness: [String: [MachineReadiness]], preferred: String?
  ) -> [String] {
    let reachable = machines.filter(\.isReachable)
    let ready = Set(
      reachable.filter { machine in
        guard let key = machine.syncKey else { return false }
        return readiness[key]?.contains { $0.harnessId == harnessId && $0.state == "ready" } == true
      }.map(\.id))
    var ordered: [String] = []
    if let preferred, reachable.contains(where: { $0.id == preferred }) { ordered.append(preferred) }
    ordered += reachable.map(\.id).filter { ready.contains($0) && !ordered.contains($0) }
    ordered += reachable.map(\.id).filter { !ordered.contains($0) }
    return ordered
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
