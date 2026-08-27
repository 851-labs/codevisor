import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Harnesses pane: the machines ARE the page. One disclosure per
/// machine with that machine's harnesses inside — installs, sign-ins, and
/// updates are all genuinely per machine.
struct HarnessesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            MachineConfigSections(badge: badge) { machine in
                HarnessMachinePane(machine: machine)
            }
            Section {
            } footer: {
                Text(
                    "Harnesses are installed and signed in per machine. Which harnesses are enabled syncs across your fleet."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .settingsPaneFormStyle(theme)
        .background {
            if !theme.isSystem { theme.windowBackground }
        }
    }

    /// The disclosure-row badge, from the machine's own readiness report:
    /// a harness waiting on sign-in needs the user; a machine with no
    /// report yet is still converging.
    private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
        if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
            return .attention("Unreachable")
        }
        guard let key = environment.machines.syncKey(forMachineId: machine.id),
            let rows = HarnessFleet.readiness(environment.configSync)[key]
        else { return .syncing }
        if rows.contains(where: { $0.state == "signInRequired" }) {
            return .attention("Sign in required")
        }
        return .synced
    }
}

#Preview("Harnesses") {
    HarnessesSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 520, height: 420)
}
