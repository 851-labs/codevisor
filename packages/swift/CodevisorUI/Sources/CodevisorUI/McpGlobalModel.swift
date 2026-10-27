import CodevisorCore
import Foundation
import Observation

@MainActor @Observable
public final class McpGlobalModel {
  public private(set) var state = McpFleetState(preferredMachineId: CodevisorMachine.local.id)
  public private(set) var browserByMachine: [String: ServerBrowserUseConfiguration] = [:]
  public private(set) var isLoading = true
  public var actionError: String?

  @ObservationIgnored private let pendingTimeout: Duration
  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  @ObservationIgnored private var latestRequest: [String: Int] = [:]

  public init(pendingTimeout: Duration = .seconds(30)) {
    self.pendingTimeout = pendingTimeout
  }

  public var entries: [McpFleetEntry] { state.entries }
  public var builtIns: [McpFleetEntry] { entries.filter(\.isBuiltIn) }
  public var managed: [McpFleetEntry] { entries.filter { !$0.isBuiltIn } }

  public var installedCatalogIds: Set<String> {
    Set(entries.flatMap { $0.serverByMachine.values.compactMap(\.catalogId) })
  }

  public func entry(named name: String) -> McpFleetEntry? {
    entries.first { $0.name == name }
  }

  public func rows(for entry: McpFleetEntry, in environment: AppEnvironment) -> [McpFleet.MachineRow] {
    state.rows(
      for: entry, sync: environment.configSync, machines: FleetMachineInfo.all(environment.machines))
  }

  public func row(
    for entry: McpFleetEntry, on machineId: String, in environment: AppEnvironment
  ) -> McpFleet.MachineRow? {
    rows(for: entry, in: environment).first { $0.machineId == machineId }
  }

  public func settle(in environment: AppEnvironment) {
    state.settle(sync: environment.configSync, machines: FleetMachineInfo.all(environment.machines))
  }

  public func scheduleReload(in environment: AppEnvironment) {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await self?.load(in: environment)
    }
  }

  public func load(in environment: AppEnvironment) async {
    let machineIds = environment.machines.allMachines.map(\.id)
    state.retainMachines(Set(machineIds))
    let fetches = machineIds.map { machineId in
      let client = environment.machines.client(for: machineId)
      return Task { @MainActor [weak self] in await self?.fetch(machineId, from: client) }
    }
    for fetch in fetches { await fetch.value }
    isLoading = false
    await loadBrowserConfigurations(in: environment)
  }

  public func setAvailability(
    _ isOn: Bool, of entry: McpFleetEntry, on machineId: String, in environment: AppEnvironment
  ) async {
    let token = state.intend(isOn, name: entry.name, on: machineId)
    expire(entry.name, on: machineId, token: token)
    do {
      try await McpAvailabilityChange(
        entry: entry, machineId: machineId, isOn: isOn, environment: environment
      ).apply()
      actionError = nil
    } catch {
      state.abandon(name: entry.name, on: machineId, token: token)
      actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }

  private func fetch(_ machineId: String, from client: any CodevisorServerClienting) async {
    let request = (latestRequest[machineId] ?? 0) &+ 1
    latestRequest[machineId] = request
    guard let servers = try? await client.listMcpServers(),
      latestRequest[machineId] == request
    else { return }
    state.absorb(servers, from: machineId)
  }

  private func expire(_ name: String, on machineId: String, token: Int) {
    Task { [weak self, pendingTimeout] in
      try? await Task.sleep(for: pendingTimeout)
      self?.state.abandon(name: name, on: machineId, token: token)
    }
  }

  private func loadBrowserConfigurations(in environment: AppEnvironment) async {
    guard let hosts = entries.first(where: { $0.kind == "browserUse" })?.serverByMachine.keys
    else { return }
    let probes = hosts.map { machineId in
      let client = environment.machines.client(for: machineId)
      return Task { @MainActor [weak self] in
        guard let configuration = try? await client.browserUseConfiguration() else { return }
        self?.browserByMachine[machineId] = configuration
      }
    }
    for probe in probes { await probe.value }
  }
}
