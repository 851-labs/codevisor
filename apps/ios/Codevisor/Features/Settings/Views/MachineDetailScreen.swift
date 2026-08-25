import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

/// One machine's page: connection info, selection, rename, and removal.
/// Agents, MCPs, skills, and plugins are fleet-synced config and live at
/// the top level of Settings instead of being nested per machine.
struct MachineDetailScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let machineId: String

    @State private var isRenaming = false
    @State private var renameText = ""

    private var machines: MachineController { environment.machines }
    private var machine: CodevisorMachine? { machines.machine(for: machineId) }

    var body: some View {
        List {
            if let machine {
                Section {
                    LabeledContent("Endpoint", value: machine.baseURL.absoluteString)
                    LabeledContent(
                        "Status",
                        value: machines.statusByMachineId[machine.id]?.label ?? "Connecting…"
                    )
                    if machine.id != machines.selectedMachineId {
                        Button("Use This Machine") {
                            machines.selectMachine(machine.id)
                            Task { await environment.prepareSelectedMachine() }
                        }
                    }
                }
                Section {
                    Button("Rename…") {
                        renameText = machine.name
                        isRenaming = true
                    }
                    Button("Remove Machine…", role: .destructive) {
                        try? machines.removeMachine(machine.id)
                        dismiss()
                    }
                } footer: {
                    Text("Codevisor forgets this machine. Nothing on the machine itself is changed.")
                }
            }
        }
        .navigationTitle(machine?.name ?? "Machine")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Machine", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                try? machines.renameMachine(machineId, to: renameText)
                isRenaming = false
            }
            Button("Cancel", role: .cancel) { isRenaming = false }
        }
    }
}
