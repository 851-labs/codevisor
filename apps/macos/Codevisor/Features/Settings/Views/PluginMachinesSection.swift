import CodevisorCore
import CodevisorUI
import SwiftUI

/// Settings ▸ Plugins: what each machine reports for the fleet's plugins
/// (Phase 24) — including blocked installs with their reasons ("needs
/// ffmpeg") and machine-only linked/dev plugins that never sync.
struct PluginMachinesSection: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // Reading the revision keeps this section live as gossip arrives.
        let _ = environment.configSync.revisionsByNamespace["plugin-readiness"]
        let readiness = PluginFleet.readiness(environment.configSync)
        MachineFleetSection(rowsByMachine: readiness, badge: badge) { _, entry in
            readinessRow(entry)
        }
    }

    private func badge(
        _ machineId: String, _ rows: [PluginFleet.MachineReadiness]
    ) -> MachineSyncBadge {
        if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
        if rows.contains(where: { $0.state == "notInstalled" }) { return .syncing }
        return .synced
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
