import CodevisorCore
import CodevisorUI
import SwiftUI

/// Settings ▸ MCP Servers: one disclosure per machine — sync badge on the
/// row, that machine's MCP reports and per-machine disable toggles inside.
struct McpMachinesSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let _ = environment.configSync.revisionsByNamespace["mcp-readiness"]
        let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
        let readiness = McpFleet.readiness(environment.configSync)
        MachineFleetSection(rowsByMachine: readiness, badge: badge) { machineId, entry in
            McpMachineRow(machineId: machineId, entry: entry)
        }
    }

    private func badge(_ machineId: String, _ rows: [McpFleet.MachineReadiness]) -> MachineSyncBadge {
        if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
        if rows.contains(where: { $0.state == "connecting" }) { return .syncing }
        return .synced
    }
}

private struct McpMachineRow: View {
    @Environment(AppEnvironment.self) private var environment
    let machineId: String
    let entry: McpFleet.MachineReadiness

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                Text(entry.reason ?? stateLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable \(entry.name) on this machine",
                isOn: Binding(
                    get: {
                        !McpFleet.isDisabled(
                            environment.configSync, machineId: machineId, name: entry.name)
                    },
                    set: { enabled in
                        McpFleet.setDisabled(
                            environment.configSync,
                            machineId: machineId,
                            name: entry.name,
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

    private var stateColor: Color {
        switch entry.state {
        case "ready": .green
        case "connecting", "idle": .secondary.opacity(0.6)
        case "blocked": .orange
        default: .secondary.opacity(0.35)
        }
    }

    private var stateLabel: String {
        switch entry.state {
        case "ready": "Ready"
        case "connecting": "Connecting"
        case "blocked": "Blocked"
        default: entry.state
        }
    }
}
