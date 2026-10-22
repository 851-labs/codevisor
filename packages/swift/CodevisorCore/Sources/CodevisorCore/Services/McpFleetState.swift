import Foundation

public struct McpFleetState: Equatable, Sendable {
  public struct IntentKey: Hashable, Sendable {
    public var name: String
    public var machineId: String

    public init(name: String, machineId: String) {
      self.name = name
      self.machineId = machineId
    }
  }

  public struct Intent: Equatable, Sendable {
    public var isOn: Bool
    public var token: Int
  }

  public private(set) var serversByMachine: [String: [ServerMcpServer]] = [:]
  public private(set) var intents: [IntentKey: Intent] = [:]
  public var preferredMachineId: String?
  private var nextToken = 0

  public init(preferredMachineId: String? = nil) {
    self.preferredMachineId = preferredMachineId
  }

  public var entries: [McpFleetEntry] {
    var byName: [String: [String: ServerMcpServer]] = [:]
    for (machineId, servers) in serversByMachine {
      for server in servers { byName[server.name, default: [:]][machineId] = server }
    }
    return
      byName
      .compactMap { McpFleetEntry(name: $0, serverByMachine: $1, preferredMachineId: preferredMachineId) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public mutating func absorb(_ servers: [ServerMcpServer], from machineId: String) {
    serversByMachine[machineId] = servers
  }

  public mutating func retainMachines(_ machineIds: Set<String>) {
    serversByMachine = serversByMachine.filter { machineIds.contains($0.key) }
    intents = intents.filter { machineIds.contains($0.key.machineId) }
  }

  @discardableResult
  public mutating func intend(_ isOn: Bool, name: String, on machineId: String) -> Int {
    nextToken &+= 1
    intents[IntentKey(name: name, machineId: machineId)] = Intent(isOn: isOn, token: nextToken)
    return nextToken
  }

  public mutating func abandon(name: String, on machineId: String, token: Int) {
    let key = IntentKey(name: name, machineId: machineId)
    guard intents[key]?.token == token else { return }
    intents[key] = nil
  }

  public mutating func settle(
    readiness: [String: [McpFleet.MachineReadiness]], machines: [FleetMachineInfo]
  ) {
    let syncKeys = Dictionary(machines.map { ($0.id, $0.syncKey) }, uniquingKeysWith: { first, _ in first })
    intents = intents.filter { key, intent in
      guard let syncKey = syncKeys[key.machineId] ?? nil,
        let reported = readiness[syncKey]?.first(where: { $0.name == key.name })
      else { return true }
      return McpFleet.isReportedOn(reported) != intent.isOn
    }
  }

  public func rows(
    for entry: McpFleetEntry,
    readiness: [String: [McpFleet.MachineReadiness]],
    overlayDisabled: Set<String>,
    fleetEnabled: Bool?,
    machines: [FleetMachineInfo]
  ) -> [McpFleet.MachineRow] {
    let fleetOn = fleetEnabled ?? entry.representative.enabled
    return McpFleet.machineRows(
      name: entry.name,
      readiness: readiness,
      machines: machines,
      desiredOn: { machine in
        let overlayOff = machine.syncKey.map(overlayDisabled.contains) ?? false
        guard !overlayOff else { return false }
        guard entry.isMachineScoped else { return fleetOn }
        return entry.server(on: machine.id)?.enabled ?? false
      },
      intents: intents(for: entry.name))
  }

  @MainActor
  public func rows(
    for entry: McpFleetEntry, sync: ConfigSync, machines: [FleetMachineInfo]
  ) -> [McpFleet.MachineRow] {
    for namespace in McpFleet.syncNamespaces { _ = sync.revisionsByNamespace[namespace] }
    return rows(
      for: entry,
      readiness: McpFleet.readiness(sync),
      overlayDisabled: McpFleet.overlayDisabledKeys(sync, name: entry.name, machines: machines),
      fleetEnabled: McpFleet.fleetEnabled(sync, name: entry.name),
      machines: machines)
  }

  @MainActor
  public mutating func settle(sync: ConfigSync, machines: [FleetMachineInfo]) {
    settle(readiness: McpFleet.readiness(sync), machines: machines)
  }

  private func intents(for name: String) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for (key, intent) in intents where key.name == name { result[key.machineId] = intent.isOn }
    return result
  }
}
