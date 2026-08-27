import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Plugins pane: the machines ARE the page. One disclosure per machine
/// with that machine's plugins inside — install, update, restart, and
/// uninstall all act on that machine.
struct PluginsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            MachineConfigSections(badge: badge) { machine in
                PluginMachinePane(machine: machine)
            }
            Section {
            } footer: {
                Text(
                    "Plugins installed from the registry sync across your fleet. Linked and local-path plugins stay on the machine they live on."
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
    /// blocked plugins (missing prerequisites) need the user; a fleet
    /// plugin not yet materialized there is still converging.
    private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
        if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
            return .attention("Unreachable")
        }
        guard let key = environment.machines.syncKey(forMachineId: machine.id),
            let rows = PluginFleet.readiness(environment.configSync)[key]
        else { return .syncing }
        if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
        if rows.contains(where: { $0.state == "notInstalled" }) { return .syncing }
        return .synced
    }
}

#Preview("Plugins Settings") {
    PluginsSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}
