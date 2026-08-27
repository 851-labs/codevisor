import CodevisorCore
import CodevisorUI
import SwiftUI

/// The one shape every config pane shares: the machines ARE the page. One
/// disclosure per machine — sync badge on the row, that machine's
/// full-fidelity rows inside. A single-machine fleet skips the disclosure
/// chrome entirely and shows its one machine's rows flat.
struct MachineConfigSections<Content: View>: View {
    @Environment(AppEnvironment.self) private var environment
    let badge: (CodevisorMachine) -> MachineSyncBadge
    @ViewBuilder let content: (CodevisorMachine) -> Content
    /// The local machine starts expanded: it is where the user is sitting,
    /// and the most likely target of whatever they came here to do.
    @State private var expandedMachines: Set<String> = [CodevisorMachine.local.id]

    var body: some View {
        let machines = environment.machines.allMachines
        if machines.count == 1, let only = machines.first {
            Section {
                content(only)
            }
        } else {
            ForEach(machines) { machine in
                Section {
                    SettingsDisclosureRow(isExpanded: expansionBinding(machine.id)) {
                        HStack {
                            Text(machine.name)
                            Spacer(minLength: 12)
                            badge(machine).view
                                .font(.callout)
                        }
                    } content: {
                        content(machine)
                            .padding(.leading, 17)
                            .padding(.top, 6)
                    }
                }
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
}
