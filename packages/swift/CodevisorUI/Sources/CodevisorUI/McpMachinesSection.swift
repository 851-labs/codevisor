import CodevisorCore
import SwiftUI

public struct McpMachinesSection: View {
  @Environment(AppEnvironment.self) private var environment
  private let entry: McpFleetEntry
  private let model: McpGlobalModel
  private let disabledReason: (_ machineId: String) -> String?

  public init(
    entry: McpFleetEntry, model: McpGlobalModel,
    disabledReason: @escaping (_ machineId: String) -> String? = { _ in nil }
  ) {
    self.entry = entry
    self.model = model
    self.disabledReason = disabledReason
  }

  public var body: some View {
    Section("Machines") {
      ForEach(model.rows(for: entry, in: environment)) { row in
        FleetMachineRow(
          machineId: row.machineId, name: row.name, status: row.status.rowStatus, details: details(for: row),
          leadingInset: 0
        ) {
          McpMachineTrailing(
            entry: entry, row: row, model: model, disabledReason: disabledReason(row.machineId))
        }
      }
    }
  }

  private func details(for row: McpFleet.MachineRow) -> FleetBlockedMachine? {
    guard let reason = row.status.rowStatus.reason else { return nil }
    return FleetBlockedMachine(
      plane: .mcps, machineId: row.machineId, machineName: row.name,
      entryName: entry.name, reason: reason)
  }
}
