import CodevisorCore
import CodevisorUI
import SwiftUI

/// Settings ▸ Agents: what each machine reports for its harnesses — the
/// desired-vs-reported matrix (Phase 24). Mirrors McpMachinesSection; a
/// sign-in-required row is tappable straight into that machine's sign-in
/// sheet.
struct HarnessMachinesSection: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var expandedMachines: Set<String> = []
    @State private var signInTarget: PendingMachineHarnessSignIn?

    var body: some View {
        // Reading the revision keeps this section live as gossip arrives.
        let _ = environment.configSync.revisionsByNamespace["harness-readiness"]
        let readiness = HarnessFleet.readiness(environment.configSync)
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
                    "Each machine reports whether the fleet's agents are installed and signed in there."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .sheet(item: $signInTarget) { target in
                HarnessSignInSheet(serverId: target.machineId, harnessId: target.harnessId)
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

    private func readinessRow(
        machineId: String, entry: HarnessFleet.MachineReadiness
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(stateColor(entry.state))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(harnessName(entry.harnessId))
                Text(entry.reason ?? stateLabel(entry.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.state == "signInRequired" {
                Button("Sign In…") {
                    signInTarget = PendingMachineHarnessSignIn(
                        machineId: machineId, harnessId: entry.harnessId)
                }
                .settingsActionTint(theme)
            }
        }
    }

    private func harnessName(_ id: String) -> String {
        id.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "ready": .green
        case "signInRequired": .orange
        case "notInstalled": .secondary.opacity(0.6)
        default: .secondary.opacity(0.35)
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "ready": "Ready"
        case "signInRequired": "Sign in required"
        case "notInstalled": "Installing / not installed"
        case "disabled": "Disabled"
        default: state
        }
    }
}

/// Sheet-item pairing of one machine and one harness needing sign-in.
struct PendingMachineHarnessSignIn: Identifiable {
    let machineId: String
    let harnessId: String
    var id: String { "\(machineId)|\(harnessId)" }
}
