#if os(iOS)
  import CodevisorCore
  import SwiftUI

  struct McpMachineToggleRow: View {
    @Environment(AppEnvironment.self) private var environment
    let entry: McpFleetEntry
    let row: McpFleet.MachineRow
    let model: McpGlobalModel
    let details: FleetBlockedMachine?

    var body: some View {
      HStack(spacing: 12) {
        if entry.isAlwaysOn {
          label
        } else {
          Toggle(isOn: availability) { label }
            .disabled(row.status == .unreachable)
        }
        FleetStatusMark(status: row.status.rowStatus, details: details)
      }
    }

    private var label: some View {
      HStack(spacing: 10) {
        MachineIconView(machineId: row.machineId)
        Text(row.name).lineLimit(1)
        Spacer(minLength: 8)
      }
    }

    private var availability: Binding<Bool> {
      Binding(
        get: { row.isOn },
        set: { next in
          Task { await model.setAvailability(next, of: entry, on: row.machineId, in: environment) }
        })
    }
  }
#endif
