import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Plugins pane: a native machine list that pushes each machine's
/// plugins — install, update, restart, and uninstall all act on that
/// machine.
struct PluginsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            MachineListSection(pane: .plugins, badge: badge) { machine in
                PluginMachinePane(machine: machine)
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
