import CodevisorCore
import CodevisorUI
import SwiftUI

/// The Skills pane: the machines ARE the page. One disclosure per machine
/// with that machine's skill store inside — the fleet ferries skill content
/// between machines, and each machine reports how in-sync it is.
struct SkillsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    var body: some View {
        Form {
            MachineConfigSections(badge: badge) { machine in
                SkillMachinePane(machine: machine)
            }
            Section {
            } footer: {
                Text("Skills sync across your fleet — a skill added here appears on every machine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPaneFormStyle(theme)
        .background {
            if !theme.isSystem { theme.windowBackground }
        }
    }

    /// Skills have no readiness plane — their single source of truth is the
    /// synced tree hash, so the badge derives from reachability alone and
    /// the pane's own banners carry the out-of-sync details.
    private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
        if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
            return .attention("Unreachable")
        }
        return .synced
    }
}

#Preview("Skills") {
    SkillsSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}
