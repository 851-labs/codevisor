import CodevisorCore
import Foundation
import Observation

/// Shared state for the skill fleet list. The replicated "skills" namespace
/// carries a name and a tree hash; the frontmatter name a machine scanned,
/// and any skill a machine has that the fleet has never seen, come from the
/// machines themselves.
@MainActor @Observable
public final class SkillGlobalModel {
  /// Skills only one machine has, keyed by directory name.
  public internal(set) var localOnly: [String: String] = [:]
  public internal(set) var namesByDirectory: [String: String] = [:]
  public var isLoading = true
  public var loadFailed = false
  public var actionError: String?

  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  /// Discards answers from a sweep that a newer one has replaced.
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored private var answered = false
  @ObservationIgnored private var seenByMachine: [String: Set<String>] = [:]
  @ObservationIgnored private var machineNames: [String: String] = [:]

  public init() {}

  /// Coalesces bursts of state events into one refetch. A machine that
  /// crashes and restarts a plugin, or settles three MCP connections in a
  /// row, must not cost one list call per machine per event.
  public func scheduleReload(in environment: AppEnvironment) {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await self?.load(in: environment)
    }
  }

  /// Every skill the list shows: the fleet's set, then anything a machine
  /// has that hasn't been published yet.
  public func entries(_ sync: ConfigSync) -> [SkillFleetEntry] {
    var result: [String: SkillFleetEntry] = [:]
    for setting in SkillFleet.settings(sync) {
      result[setting.directoryName] = SkillFleetEntry(
        directoryName: setting.directoryName,
        name: namesByDirectory[setting.directoryName] ?? setting.name)
    }
    for (directoryName, machineName) in localOnly where result[directoryName] == nil {
      result[directoryName] = SkillFleetEntry(
        directoryName: directoryName,
        name: namesByDirectory[directoryName] ?? directoryName,
        localOnlyMachineName: machineName)
    }
    return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Fans the scan out across every machine. Only metadata is merged: the
  /// per-machine condition comes from the readiness replica, not from here,
  /// so an unreachable machine no longer blanks the page.
  /// Asks every machine at once and publishes each answer as it lands. The
  /// per-machine condition comes from the readiness replica, not from here,
  /// so an unreachable machine no longer blanks the page — or holds it on
  /// "Loading…" for the length of its timeout.
  public func load(in environment: AppEnvironment) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    defer { if generation == loadGeneration { isLoading = false } }
    namesByDirectory = [:]
    seenByMachine = [:]
    machineNames = [:]
    answered = false
    // Every machine is asked at once and publishes its own answer the moment
    // it lands. The per-machine condition comes from the readiness replica,
    // not from here, so an unreachable machine neither blanks the page nor
    // holds it on "Loading…" for the length of its timeout.
    let probes = environment.machines.allMachines.map { machine in
      let client = environment.machines.client(for: machine.id)
      return Task { @MainActor [weak self] in
        let scan = try? await client.listSkills()
        guard let self, generation == self.loadGeneration, let scan else { return }
        self.absorb(scan, from: machine, in: environment)
      }
    }
    for probe in probes { await probe.value }
    guard generation == loadGeneration else { return }
    loadFailed = !answered
  }

  private func absorb(
    _ scan: ServerSkillsScan, from machine: CodevisorMachine, in environment: AppEnvironment
  ) {
    answered = true
    loadFailed = false
    machineNames[machine.id] = machine.name
    seenByMachine[machine.id] = Set(scan.global.map(\.directoryName))
    for skill in scan.global where namesByDirectory[skill.directoryName] == nil {
      namesByDirectory[skill.directoryName] = skill.name
    }
    // A skill the fleet has never seen belongs to the machine that has it.
    let fleetNames = Set(SkillFleet.settings(environment.configSync).map(\.directoryName))
    var bound: [String: String] = [:]
    for (machineId, directoryNames) in seenByMachine {
      for directoryName in directoryNames where !fleetNames.contains(directoryName) {
        bound[directoryName] = machineNames[machineId] ?? machineId
      }
    }
    localOnly = bound
  }
}
