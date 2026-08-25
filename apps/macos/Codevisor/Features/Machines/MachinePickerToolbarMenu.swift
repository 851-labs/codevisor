import SwiftUI
import CodevisorCore
import CodevisorUI

/// The compact machine selector that stays available in the window toolbar.
/// Its glyph reflects the selected machine kind and inherits the active
/// theme's semantic foreground color.
struct MachinePickerToolbarMenu: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openSettings) private var openSettings
    @Environment(\.theme) private var theme

    private var machines: MachineController { environment.machines }
    private var selectedMachine: CodevisorMachine { machines.selectedMachine }

    /// Chats needing attention on a machine — the fleet's ambient unread.
    private func unreadCount(for machineId: String) -> Int {
        environment.projectList.sessions.filter {
            $0.serverId == machineId && SessionAttentionSummary($0).hasUnseenAttention
        }.count
    }

    /// A quiet dot on the picker when a NON-selected machine needs you.
    private var hasBackgroundUnread: Bool {
        machines.allMachines.contains {
            $0.id != machines.selectedMachineId && unreadCount(for: $0.id) > 0
        }
    }

    var body: some View {
        Menu {
            // One list for everything the app can reach: configured machines
            // and cloud-relay machines alike, all selectable the same way.
            ForEach(machines.allMachines) { machine in
                Toggle(
                    isOn: Binding(
                        get: { machine.id == machines.selectedMachineId },
                        set: { isOn in
                            guard isOn else { return }
                            machines.selectMachine(machine.id)
                        }
                    )
                ) {
                    Label {
                        let unread = unreadCount(for: machine.id)
                        Text(unread > 0 ? "\(machine.name) (\(unread))" : machine.name)
                    } icon: {
                        MenuSymbolIcon(systemName: EntitySystemSymbol.machine(machine))
                    }
                }
            }

            Divider()

            Button("Manage Machines…") {
                SettingsRouter.shared.showMachines()
                openSettings()
            }
        } label: {
            Image(systemName: EntitySystemSymbol.machine(selectedMachine))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.textPrimary)
                // SF Symbols have different intrinsic widths. Give every
                // machine glyph the same centered slot so the menu doesn't
                // effectively leading-align wider symbols.
                .frame(width: 20, height: 20, alignment: .center)
                .overlay(alignment: .topTrailing) {
                    if hasBackgroundUnread {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -1)
                            .accessibilityLabel("Unread chats on another machine")
                    }
                }
        }
        .menuIndicator(.hidden)
        .help("Switch machine — \(selectedMachine.name)")
        .accessibilityLabel("Machine: \(selectedMachine.name)")
    }
}
