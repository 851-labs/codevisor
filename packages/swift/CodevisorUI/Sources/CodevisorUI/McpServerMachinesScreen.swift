import CodevisorCore
import SwiftUI

#if os(iOS)
  struct McpServerMachinesScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let serverName: String
    let model: McpGlobalModel
    let onConnect: (McpFleetEntry, _ machineId: String) -> Void
    let onEdit: (McpFleetEntry) -> Void
    let onRemove: (McpFleetEntry) -> Void
    let toggleDisabledReason: (McpFleetEntry, _ machineId: String) -> String?

    var body: some View {
      let entry = model.entry(named: serverName)
      List {
        if let entry {
          if needsAuthorization(entry),
            let machineId = entry.machineId(preferring: nil)
          {
            Section {
              Button("Connect…") { onConnect(entry, machineId) }
            }
          }
          Section {
            ForEach(machineRows(entry)) { row in
              McpMachineDetailRow(
                entry: entry, row: row, model: model,
                disabledReason: toggleDisabledReason(entry, row.machineId))
            }
          } header: {
            Text("Machines")
          }
          if entry.canEdit || entry.canRemove {
            Section {
              if entry.canEdit {
                Button("Edit Server") { onEdit(entry) }
              }
              if entry.canRemove {
                Button("Remove Server", role: .destructive) {
                  dismiss()
                  onRemove(entry)
                }
                .foregroundStyle(.red)
              }
            }
          }
        } else {
          Text("This server is no longer in your fleet.").foregroundStyle(.secondary)
        }
      }
      .navigationTitle(serverName)
      .navigationBarTitleDisplayMode(.inline)
    }

    private func machineRows(_ entry: McpFleetEntry) -> [McpFleet.MachineRow] {
      model.rows(for: entry, in: environment)
    }

    private func needsAuthorization(_ entry: McpFleetEntry) -> Bool {
      entry.authType == "oauth"
        && machineRows(entry).contains { $0.isOn && $0.status.needsAuthorization }
    }
  }

  private struct McpMachineDetailRow: View {
    @Environment(AppEnvironment.self) private var environment
    let entry: McpFleetEntry
    let row: McpFleet.MachineRow
    let model: McpGlobalModel
    let disabledReason: String?
    @State private var blocked: FleetBlockedMachine?

    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 12) {
          Text(row.name)
          Spacer(minLength: 8)
          McpMachineTrailing(
            entry: entry, row: row, model: model, disabledReason: disabledReason)
        }
        Button {
          guard row.status.rowStatus.reason != nil else { return }
          blocked = details
        } label: {
          HStack(spacing: 6) {
            FleetStatusMark(status: row.status.rowStatus)
              .accessibilityHidden(true)
            Text(row.status.label)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
        .disabled(row.status.rowStatus.reason == nil)
      }
      .fleetBlockedDetails(item: $blocked)
    }

    private var details: FleetBlockedMachine? {
      guard let reason = row.status.rowStatus.reason else { return nil }
      return FleetBlockedMachine(
        plane: .mcps, machineId: row.machineId, machineName: row.name,
        entryName: entry.name, reason: reason)
    }
  }
#endif
