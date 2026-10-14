import CodevisorCore
import Foundation
import Observation

public struct McpFleetEntry: Identifiable, Equatable, Sendable {
  public var name: String
  public var kind: String?
  public var transport: String
  public var authType: String
  public var enabled: Bool
  public var canEdit: Bool
  public var canRemove: Bool
  public var idByMachine: [String: String]
  public var enabledByMachine: [String: Bool] = [:]
  public var turningOnMachines: Set<String> = []
  public var representative: ServerMcpServer
  public var id: String { name }

  public var isBuiltIn: Bool { representative.isBuiltIn }

  public var isMachineScoped: Bool { isBuiltIn }

  public func machineId(preferring preferred: String?) -> String? {
    if let preferred, idByMachine[preferred] != nil { return preferred }
    return idByMachine.keys.sorted().first
  }
}

@MainActor @Observable
public final class McpGlobalModel {
  public private(set) var entries: [McpFleetEntry] = []
  public private(set) var browserByMachine: [String: ServerBrowserUseConfiguration] = [:]
  public private(set) var respondingMachines: Set<String> = []
  public var isLoading = true
  public var actionError: String?

  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  @ObservationIgnored private var loadGeneration = 0
  @ObservationIgnored private var merged: [String: McpFleetEntry] = [:]
  @ObservationIgnored private var pendingEnabled: [String: Bool] = [:]

  public init() {}

  public func scheduleReload(in environment: AppEnvironment) {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      await self?.load(in: environment)
    }
  }

  public var builtIns: [McpFleetEntry] { entries.filter(\.isBuiltIn) }
  public var managed: [McpFleetEntry] { entries.filter { !$0.isBuiltIn } }

  public func entry(named name: String) -> McpFleetEntry? {
    entries.first { $0.name == name }
  }

  @MainActor
  static func machineRows(
    entry: McpFleetEntry, sync: ConfigSync, machines: [FleetMachineInfo]
  ) -> [McpFleet.MachineRow] {
    McpFleet.rowsRespectingBuiltIns(
      name: entry.name, isMachineScoped: entry.isMachineScoped,
      enabledByMachine: entry.enabledByMachine, fleetEnabled: entry.enabled,
      turningOn: entry.turningOnMachines, sync: sync, machines: machines)
  }

  public func load(in environment: AppEnvironment) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    defer { if generation == loadGeneration { isLoading = false } }
    merged = [:]
    respondingMachines = []
    let probes = environment.machines.allMachines.map { machine in
      let client = environment.machines.client(for: machine.id)
      return Task { @MainActor [weak self] in
        let servers = try? await client.listMcpServers()
        guard let self, generation == self.loadGeneration, let servers else { return }
        self.absorb(servers, from: machine.id)
      }
    }
    for probe in probes { await probe.value }
    guard generation == loadGeneration else { return }
    await loadBrowserConfigurations(in: environment)
  }

  private func absorb(_ servers: [ServerMcpServer], from machineId: String) {
    respondingMachines.insert(machineId)
    for server in servers {
      merge(server, from: machineId, into: &merged)
    }
    publish(merged)
  }

  private func loadBrowserConfigurations(in environment: AppEnvironment) async {
    guard let hosts = merged.values.first(where: { $0.kind == "browserUse" })?.idByMachine.keys
    else { return }
    let probes = hosts.map { machineId in
      let client = environment.machines.client(for: machineId)
      return Task { @MainActor [weak self] in
        let configuration = try? await client.browserUseConfiguration()
        guard let self, let configuration else { return }
        self.browserByMachine[machineId] = configuration
      }
    }
    for probe in probes { await probe.value }
  }

  private func publish(_ merged: [String: McpFleetEntry]) {
    entries = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func merge(
    _ incoming: ServerMcpServer, from machineId: String, into merged: inout [String: McpFleetEntry]
  ) {
    var server = incoming
    let pending = pendingEnabled["\(server.name)|\(machineId)"]
    if let pending { server.enabled = pending }
    defer { if pending == true { merged[server.name]?.turningOnMachines.insert(machineId) } }
    if var existing = merged[server.name] {
      existing.idByMachine[machineId] = server.id
      existing.enabledByMachine[machineId] = server.enabled
      if server.connectionState == "connected",
        existing.representative.connectionState != "connected"
      {
        existing.representative = server
      }
      merged[server.name] = existing
    } else {
      merged[server.name] = McpFleetEntry(
        name: server.name,
        kind: server.kind,
        transport: server.transport,
        authType: server.authType,
        enabled: server.enabled,
        canEdit: server.canEdit != false,
        canRemove: server.canRemove != false,
        idByMachine: [machineId: server.id],
        enabledByMachine: [machineId: server.enabled],
        representative: server)
    }
    if !server.enabled, merged[server.name]?.isMachineScoped == false {
      merged[server.name]?.enabled = false
    }
  }

  public func setEnabled(
    _ entry: McpFleetEntry, on machineId: String, enabled: Bool, in environment: AppEnvironment
  ) async {
    guard let serverId = entry.idByMachine[machineId] else {
      actionError = "\(entry.name) isn’t on that machine yet."
      return
    }
    let key = "\(entry.name)|\(machineId)"
    pendingEnabled[key] = enabled
    applyEnabled(entry.name, on: machineId, enabled: enabled)
    do {
      _ = try await environment.machines.client(for: machineId)
        .setMcpServerEnabled(id: serverId, enabled: enabled)
      actionError = nil
      if pendingEnabled[key] == enabled { pendingEnabled[key] = nil }
      await load(in: environment)
    } catch {
      actionError = ErrorReporter.userFacingMessage(for: error)
      if pendingEnabled[key] == enabled { pendingEnabled[key] = nil }
      await load(in: environment)
    }
  }

  private func applyEnabled(_ name: String, on machineId: String, enabled: Bool) {
    guard var entry = merged[name] else { return }
    entry.enabledByMachine[machineId] = enabled
    if enabled { entry.turningOnMachines.insert(machineId) } else { entry.turningOnMachines.remove(machineId) }
    if !entry.isMachineScoped {
      entry.enabled = enabled
      for id in entry.enabledByMachine.keys { entry.enabledByMachine[id] = enabled }
    }
    merged[name] = entry
    publish(merged)
  }

  public func setFleetEnabled(
    _ entry: McpFleetEntry, enabled: Bool, in environment: AppEnvironment
  ) async {
    guard let machineId = entry.machineId(preferring: CodevisorMachine.local.id) else {
      actionError = "No machine has this server yet."
      return
    }
    await setEnabled(entry, on: machineId, enabled: enabled, in: environment)
  }
}
