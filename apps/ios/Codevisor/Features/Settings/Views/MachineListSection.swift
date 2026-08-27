import CodevisorCore
import CodevisorUI
import SwiftUI

/// The one shape every config screen root shares: a native list of
/// machines — sync badge on the row — that pushes each machine's screen,
/// the HIG's list-of-things-with-rich-detail pattern. A single-machine
/// fleet skips the list and shows its one machine's rows inline.
struct MachineListSection<Content: View>: View {
    @Environment(AppEnvironment.self) private var environment
    let badge: (CodevisorMachine) -> MachineSyncBadge
    @ViewBuilder let content: (CodevisorMachine) -> Content

    var body: some View {
        let machines = environment.machines.allMachines
        if machines.count == 1, let only = machines.first {
            Section {
                content(only)
            }
        } else {
            Section {
                ForEach(machines) { machine in
                    NavigationLink {
                        List {
                            content(machine)
                        }
                        .navigationTitle(machine.name)
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            Text(machine.name)
                            Spacer(minLength: 12)
                            badge(machine).view
                                .font(.footnote)
                        }
                    }
                }
            }
        }
    }
}
