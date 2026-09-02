import CodevisorCore
import CodevisorUI
import SwiftUI

/// A machine's page inside a config pane. The pane root lists machines;
/// selecting one pushes its page — the System Settings shape for
/// list-of-things-with-rich-detail, per the HIG's guidance that disclosure
/// controls are for small supplementary content only.
struct MachinePaneRoute: Hashable {
    enum Pane: Hashable {
        case mcps, harnesses, plugins, skills
    }

    let pane: Pane
    let machineId: String
}

/// The one shape every config pane root shares: a native list of machines —
/// sync badge on the row — that pushes each machine's page. A
/// single-machine fleet skips the list and shows its one machine's sections
/// inline.
struct MachineListSection<Content: View, Footer: View>: View {
    @Environment(AppEnvironment.self) private var environment
    let pane: MachinePaneRoute.Pane
    let badge: (CodevisorMachine) -> MachineSyncBadge
    let content: (CodevisorMachine) -> Content
    /// Fleet-level list actions. A single-machine fleet renders that
    /// machine's own actions inline, so the footer only shows under a list.
    let footer: () -> Footer

    init(
        pane: MachinePaneRoute.Pane,
        badge: @escaping (CodevisorMachine) -> MachineSyncBadge,
        @ViewBuilder content: @escaping (CodevisorMachine) -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.pane = pane
        self.badge = badge
        self.content = content
        self.footer = footer
    }

    var body: some View {
        let machines = environment.machines.allMachines
        if machines.count == 1, let only = machines.first {
            content(only)
        } else {
            Section {
                ForEach(machines) { machine in
                    NavigationLink(value: MachinePaneRoute(pane: pane, machineId: machine.id)) {
                        HStack {
                            Text(machine.name)
                            Spacer(minLength: 12)
                            badge(machine).view
                                .font(.callout)
                        }
                    }
                }
            } footer: {
                footer()
            }
        }
    }
}

extension MachineListSection where Footer == EmptyView {
    init(
        pane: MachinePaneRoute.Pane,
        badge: @escaping (CodevisorMachine) -> MachineSyncBadge,
        @ViewBuilder content: @escaping (CodevisorMachine) -> Content
    ) {
        self.init(pane: pane, badge: badge, content: content) { EmptyView() }
    }
}
