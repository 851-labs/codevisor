import CodevisorCore
import CodevisorUI
import SwiftUI

/// Phase 18: the fleet matrix for MCPs — one disclosure per machine showing
/// what each MCP actually looks like THERE (from the "mcp-readiness"
/// namespace), with the per-machine disable toggle ("mcp-overlays").
/// Renders only what machines have reported; hidden for single-machine
/// fleets, where the main list already tells the whole story.
struct McpMachinesSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var expandedMachines: Set<String> = []

    var body: some View {
        // Reading the revision keeps this section live as gossip arrives.
        let _ = environment.configSync.revisionsByNamespace["mcp-readiness"]
        let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
        let readiness = McpFleet.readiness(environment.configSync)
        if environment.machines.machines.count > 1, !readiness.isEmpty {
            Section {
                ForEach(readiness.keys.sorted(), id: \.self) { machineId in
                    SettingsDisclosureRow(
                        machineName(machineId),
                        isExpanded: expansionBinding(machineId)
                    ) {
                        ForEach(readiness[machineId] ?? []) { entry in
                            readinessRow(machineId: machineId, entry: entry)
                                .padding(.leading, 17)
                                .padding(.top, 6)
                        }
                    }
                }
            } header: {
                Text("On Your Machines")
            } footer: {
                Text(
                    "Each machine reports what its MCP servers look like there. Turning one off disables it on that machine only."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func machineName(_ machineId: String) -> String {
        environment.machines.fleetMachineName(for: machineId) ?? machineId
    }

    private func expansionBinding(_ machineId: String) -> Binding<Bool> {
        Binding(
            get: { expandedMachines.contains(machineId) },
            set: { expanded in
                if expanded {
                    expandedMachines.insert(machineId)
                } else {
                    expandedMachines.remove(machineId)
                }
            }
        )
    }

    private func readinessRow(machineId: String, entry: McpFleet.MachineReadiness) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(stateColor(entry.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                Text(entry.reason ?? stateLabel(entry.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable \(entry.name) on \(machineName(machineId))",
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

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "ready": .green
        case "connecting", "idle": .secondary.opacity(0.6)
        case "blocked": .orange
        default: .secondary.opacity(0.35)
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "ready": "Ready"
        case "connecting": "Connecting…"
        case "idle": "Idle — connects on use"
        case "blocked": "Blocked"
        case "disabled": "Disabled"
        case "excluded": "Pinned to other machines"
        default: state
        }
    }
}
