import SwiftUI
import AppKit
import HerdManCore

/// The Machines menu: switch the connected machine, add a remote, and jump to
/// the Machines settings tab. Also adds "Copy Connection Token" to the app
/// menu next to Settings.
struct MachineCommands: Commands {
    let machines: MachineController

    var body: some Commands {
        CommandMenu("Machines") {
            MachinePickerItems(machines: machines)
            Divider()
            AddRemoteMachineMenuItem()
            ManageMachinesMenuItem()
        }

        CommandGroup(after: .appSettings) {
            CopyConnectionTokenMenuItem(machines: machines)
        }
    }
}

/// One checkable item per known machine; picking one connects to it. The
/// selection reset to the new-chat page happens in RootView, which watches the
/// selected machine id.
private struct MachinePickerItems: View {
    let machines: MachineController

    var body: some View {
        ForEach(machines.machines) { machine in
            Toggle(machine.name, isOn: Binding(
                get: { machines.selectedMachineId == machine.id },
                set: { isOn in
                    if isOn { machines.selectMachine(machine.id) }
                }
            ))
        }
    }
}

private struct AddRemoteMachineMenuItem: View {
    @FocusedValue(\.sidebarActions) private var actions

    var body: some View {
        Button("Add Remote Machine…") { actions?.addRemoteMachine() }
            .disabled(actions == nil)
    }
}

private struct ManageMachinesMenuItem: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Manage Machines…") {
            SettingsRouter.shared.selectedTab = .machines
            openSettings()
        }
    }
}

private struct CopyConnectionTokenMenuItem: View {
    let machines: MachineController

    var body: some View {
        Button("Copy Connection Token") { copyToken() }
    }

    /// Issues a fresh token from this Mac's server and puts it on the
    /// clipboard. Failure gets an alert; success is silent, like any Copy.
    private func copyToken() {
        Task { @MainActor in
            do {
                let token = try await machines.issueLocalConnectionToken()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't issue a connection token"
                alert.informativeText = "This Mac's HerdMan server isn't running."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}
