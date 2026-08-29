import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

enum SettingsDestination: Hashable, Identifiable {
    case root
    case machines(focusedMachineID: String?)

    var id: String {
        switch self {
        case .root:
            "root"
        case let .machines(machineID):
            "machines:\(machineID ?? "all")"
        }
    }
}

/// App settings, mirroring the macOS settings window's tabs as an iOS
/// navigation list. Agents, MCPs, skills, and plugins are fleet-synced
/// config, so they sit at the top level (rendered from the selected
/// machine, whose content converges with every other machine); Machines
/// keeps what is genuinely per machine — connections, status, removal.
struct SettingsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsDestination]

    init(initialDestination: SettingsDestination = .root) {
        switch initialDestination {
        case .root:
            _path = State(initialValue: [])
        case .machines:
            _path = State(initialValue: [initialDestination])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink {
                        CloudAccountScreen()
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
                    }
                    NavigationLink(value: SettingsDestination.machines(focusedMachineID: nil)) {
                        Label("Machines", systemImage: "desktopcomputer")
                    }
                }
                Section {
                    NavigationLink {
                        UpdatesSettingsScreen()
                    } label: {
                        // badge(0) hides itself — the ambient signal simply
                        // is not there when everything is current.
                        Label("Updates", systemImage: "arrow.down.circle")
                            .badge(environment.updateCenter.availableCount)
                    }
                    NavigationLink {
                        GeneralSettingsScreen(dismissSettings: { dismiss() })
                    } label: {
                        Label("Privacy & Data", systemImage: "hand.raised")
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
                        HarnessesSettingsScreen()
                    } label: {
                        Label("Harnesses", systemImage: "brain")
                    }
                    NavigationLink {
                        McpSettingsScreen()
                    } label: {
                        Label("MCPs", systemImage: "puzzlepiece.extension")
                    }
                    NavigationLink {
                        SkillsSettingsScreen()
                    } label: {
                        Label("Skills", systemImage: "book.closed")
                    }
                    NavigationLink {
                        PluginsSettingsScreen()
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
            .navigationDestination(for: SettingsDestination.self) { destination in
                switch destination {
                case .root:
                    EmptyView()
                case let .machines(focusedMachineID):
                    MachinesSettingsScreen(focusedMachineID: focusedMachineID)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}
