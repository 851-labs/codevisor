import CodevisorCore
import SwiftUI

#if os(iOS)
  /// One MCP server's machines, as a pushed screen.
  ///
  /// A compact-width row cannot hold a name, a switch, a status and a
  /// disclosure without truncating the name — and an iOS row must not carry
  /// both a control and a navigation destination, since a tap would be
  /// ambiguous. So on iPhone the list row reports and this screen controls,
  /// which is the shape Settings.app uses for exactly this ("Wi-Fi › On").
  /// Regular width (iPad) and macOS have room to stay inline.
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
      // Re-read the entry every render: the sweep keeps landing while this
      // screen is open, and a captured copy would freeze at whatever the
      // fleet looked like when the row was tapped.
      let entry = model.entry(named: serverName)
      List {
        if let entry {
          if !entry.isMachineScoped {
            Section {
              Toggle("Enable \(entry.name)", isOn: fleetToggle(entry))
              // Authorizing is a fleet act — the material replicates and
              // every other machine adopts it — so it belongs beside the
              // fleet switch, not on any one machine's row.
              if needsAuthorization(entry),
                let machineId = entry.machineId(preferring: nil)
              {
                Button("Connect…") { onConnect(entry, machineId) }
              }
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
          // Editing and removing reach the fleet from any client, so the
          // phone gets them too — they just have nowhere to sit on a
          // compact row, which is already spoken for by the disclosure.
          if entry.canEdit || entry.canRemove {
            Section {
              if entry.canEdit {
                Button("Edit Server") { onEdit(entry) }
              }
              if entry.canRemove {
                // The role alone does not colour a list row here: the
                // themed root sets a foreground style for the whole app,
                // which wins over the role's. Every other destructive row
                // in the apps pairs the two for the same reason.
                Button("Remove Server", role: .destructive) {
                  // Both the confirmation and the result belong to the list
                  // behind this screen — staying here would leave the user
                  // on a page about a server that no longer exists.
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
      McpGlobalModel.machineRows(
        entry: entry, sync: environment.configSync,
        machines: FleetMachineInfo.all(environment.machines))
    }

    private func needsAuthorization(_ entry: McpFleetEntry) -> Bool {
      guard entry.authType == "oauth" else { return false }
      return machineRows(entry).contains {
        if case .needsAuthorization = $0.status { return true }
        return false
      }
    }

    private func fleetToggle(_ entry: McpFleetEntry) -> Binding<Bool> {
      Binding(
        get: { entry.enabled },
        set: { next in
          Task { await model.setFleetEnabled(entry, enabled: next, in: environment) }
        })
    }
  }

  /// A machine on the detail screen: the switch, the browser choice where
  /// there is one, and the failure behind its mark.
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
        // The status is its own line here: the screen has the vertical room
        // the list row did not, so nothing has to be abbreviated.
        Button {
          guard row.status.rowStatus.reason != nil else { return }
          blocked = details
        } label: {
          HStack(spacing: 6) {
            // The text beside it already says this; a mark that announces
            // itself too makes VoiceOver read the state twice.
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
