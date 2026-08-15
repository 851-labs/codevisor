import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

/// One machine's page: connection info and the settings scoped to it —
/// harnesses, MCPs, and skills all live on the machine, so they're nested
/// here rather than floating at the top level.
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
                Section("On This Machine") {
                    NavigationLink {
                        HarnessesSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("Harnesses", systemImage: "cpu")
                    }
                    NavigationLink {
                        McpSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("MCPs", systemImage: "puzzlepiece.extension")
                    }
                    NavigationLink {
                        SkillsSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("Skills", systemImage: "book.closed")
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
