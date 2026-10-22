import Foundation

@MainActor
public struct McpAvailabilityChange {
  public struct Refusal: LocalizedError {
    public let errorDescription: String?
  }

  let entry: McpFleetEntry
  let machineId: String
  let isOn: Bool
  let environment: AppEnvironment

  public init(entry: McpFleetEntry, machineId: String, isOn: Bool, environment: AppEnvironment) {
    self.entry = entry
    self.machineId = machineId
    self.isOn = isOn
    self.environment = environment
  }

  public func apply() async throws {
    if isOn { clearOverlay() }
    if usesServerFlag {
      try await setServerEnabled(isOn, preferring: machineId)
      return
    }
    guard isOn else {
      try setOverlayDisabled()
      return
    }
    guard !fleetEnabled else { return }

    disableEverywhereElse()
    try await setServerEnabled(true, preferring: machineId)
  }

  private var machines: [FleetMachineInfo] { FleetMachineInfo.all(environment.machines) }
  private var sync: ConfigSync { environment.configSync }

  private var usesServerFlag: Bool { entry.isMachineScoped || machines.count <= 1 }

  private var fleetEnabled: Bool {
    McpFleet.fleetEnabled(sync, name: entry.name) ?? entry.representative.enabled
  }

  private var syncKey: String? { environment.machines.syncKey(forMachineId: machineId) }

  private func clearOverlay() {
    guard let syncKey, McpFleet.isDisabled(sync, machineId: syncKey, name: entry.name) else { return }
    McpFleet.setDisabled(sync, machineId: syncKey, name: entry.name, disabled: false)
  }

  private func setOverlayDisabled() throws {
    guard let syncKey else {
      throw Refusal(errorDescription: "That machine hasn’t reported its identity yet.")
    }
    McpFleet.setDisabled(sync, machineId: syncKey, name: entry.name, disabled: true)
  }

  private func disableEverywhereElse() {
    for machine in machines where machine.id != machineId {
      guard let key = machine.syncKey else { continue }
      McpFleet.setDisabled(sync, machineId: key, name: entry.name, disabled: true)
    }
  }

  private func setServerEnabled(_ enabled: Bool, preferring machineId: String) async throws {
    guard let host = entry.machineId(preferring: machineId), let serverId = entry.idByMachine[host]
    else { throw Refusal(errorDescription: "\(entry.name) isn’t on that machine yet.") }
    _ = try await environment.machines.client(for: host)
      .setMcpServerEnabled(id: serverId, enabled: enabled)
  }
}
