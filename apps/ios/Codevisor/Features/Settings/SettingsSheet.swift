import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

/// App settings, mirroring the macOS settings window's tabs as an iOS
/// navigation list. Agents, MCPs, skills, and plugins are fleet-synced
/// config, so they sit at the top level (rendered from the selected
/// machine, whose content converges with every other machine); Machines
/// keeps what is genuinely per machine — connections, status, removal.
struct SettingsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    private var machines: MachineController { environment.machines }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CloudAccountScreen()
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        MachinesSettingsScreen()
                    } label: {
                        Label("Machines", systemImage: "desktopcomputer")
                    }
                }
                Section {
                    NavigationLink {
                        GeneralSettingsScreen()
                    } label: {
                        Label("General", systemImage: "gearshape")
                    }
                    NavigationLink {
                        UpdatesSettingsScreen()
                    } label: {
                        // badge(0) hides itself — the ambient signal simply
                        // is not there when everything is current.
                        Label("Updates", systemImage: "arrow.down.circle")
                            .badge(environment.updateCenter.availableCount)
                    }
                    NavigationLink {
                        AppearanceSettingsScreen()
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    NavigationLink {
                        NotificationsSettingsScreen()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }
                Section {
                    NavigationLink {
                        HarnessesSettingsScreen(
                            client: machines.client(for: machines.selectedMachineId))
                    } label: {
                        Label("Agents", systemImage: "cpu")
                    }
                    NavigationLink {
                        McpSettingsScreen(client: machines.client(for: machines.selectedMachineId))
                    } label: {
                        Label("MCPs", systemImage: "puzzlepiece.extension")
                    }
                    NavigationLink {
                        SkillsSettingsScreen(
                            client: machines.client(for: machines.selectedMachineId))
                    } label: {
                        Label("Skills", systemImage: "book.closed")
                    }
                    NavigationLink {
                        PluginsSettingsScreen(
                            client: machines.client(for: machines.selectedMachineId),
                            serverId: machines.selectedMachineId
                        )
                    } label: {
                        Label("Plugins", systemImage: "puzzlepiece")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
