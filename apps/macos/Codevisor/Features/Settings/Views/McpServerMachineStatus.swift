import CodevisorCore
import CodevisorUI
import SwiftUI

/// The per-item machine reality under a fleet MCP row (Phase 27a): a
/// one-line summary that discloses each machine's report, with the
/// per-machine disable toggle right where the state is shown.
struct McpServerMachineStatus: View {
    @Environment(AppEnvironment.self) private var environment
    let serverName: String
    @State private var isExpanded = false

    var body: some View {
        let _ = environment.configSync.revisionsByNamespace["mcp-readiness"]
        let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
        let rows = McpFleet.readinessByServer(environment.configSync)[serverName] ?? []
        if environment.machines.machines.count > 1, !rows.isEmpty {
            SettingsDisclosureRow(summary(rows), isExpanded: $isExpanded) {
                ForEach(rows) { row in
                    machineRow(row)
                        .padding(.leading, 17)
                        .padding(.top, 6)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func summary(_ rows: [McpFleet.MachineStatus]) -> String {
        let ready = rows.filter { $0.state == "ready" && !disabled($0.machineId) }.count
        let troubled = rows.filter { $0.state == "blocked" || disabled($0.machineId) }
        if troubled.isEmpty { return "Ready on \(ready) of \(rows.count) machines" }
        let names = troubled.map { machineName($0.machineId) }.joined(separator: ", ")
        return "Needs attention on \(names)"
    }

    private func machineRow(_ row: McpFleet.MachineStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(color(row))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(machineName(row.machineId))
                Text(row.reason ?? label(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable \(serverName) on \(machineName(row.machineId))",
                isOn: Binding(
                    get: { !disabled(row.machineId) },
                    set: { enabled in
                        McpFleet.setDisabled(
                            environment.configSync,
                            machineId: row.machineId,
                            name: serverName,
                            disabled: !enabled
                        )
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private func disabled(_ machineId: String) -> Bool {
        McpFleet.isDisabled(environment.configSync, machineId: machineId, name: serverName)
    }

    private func machineName(_ machineId: String) -> String {
        environment.machines.fleetMachineName(for: machineId) ?? machineId
    }

    private func color(_ row: McpFleet.MachineStatus) -> Color {
        if disabled(row.machineId) { return .secondary.opacity(0.35) }
        switch row.state {
        case "ready": return .green
        case "blocked": return .orange
        default: return .secondary.opacity(0.6)
        }
    }

    private func label(_ row: McpFleet.MachineStatus) -> String {
        if disabled(row.machineId) { return "Off on this machine" }
        switch row.state {
        case "ready": return "Ready"
        case "blocked": return "Blocked"
        default: return row.state
        }
    }
}
