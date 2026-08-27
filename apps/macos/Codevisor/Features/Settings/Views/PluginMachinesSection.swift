import CodevisorCore
import CodevisorUI
import SwiftUI

/// Settings ▸ Plugins: what each machine reports for the fleet's plugins
/// (Phase 24) — including blocked installs with their reasons ("needs
/// ffmpeg") and machine-only linked/dev plugins that never sync.
struct PluginMachinesSection: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var expandedMachines: Set<String> = []

    var body: some View {
        // Reading the revision keeps this section live as gossip arrives.
        let _ = environment.configSync.revisionsByNamespace["plugin-readiness"]
        let readiness = PluginFleet.readiness(environment.configSync)
        if environment.machines.machines.count > 1, !readiness.isEmpty {
            Section {
                ForEach(readiness.keys.sorted(), id: \.self) { machineId in
                    SettingsDisclosureRow(
                        environment.machines.fleetMachineName(for: machineId) ?? machineId,
                        isExpanded: expansionBinding(machineId)
                    ) {
                        ForEach(readiness[machineId] ?? []) { entry in
                            readinessRow(entry)
                                .padding(.leading, 17)
                                .padding(.top, 6)
                        }
                    }
                }
            } header: {
                Text("On Your Machines")
            } footer: {
                Text(
                    "Each machine reports how the fleet's plugins look there. Linked and local-path plugins stay machine-only."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
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

    private func readinessRow(_ entry: PluginFleet.MachineReadiness) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(stateColor(entry.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.pluginId)
                Text(entry.reason ?? stateLabel(entry.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "ready": .green
        case "blocked": .orange
        case "notInstalled": .secondary.opacity(0.6)
        default: .secondary.opacity(0.35)
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "ready": "Ready"
        case "disabled": "Disabled"
        case "notInstalled": "Installing / not installed"
        case "blocked": "Blocked"
        case "machineOnly": "Machine-only (linked or local path)"
        default: state
        }
    }
}
