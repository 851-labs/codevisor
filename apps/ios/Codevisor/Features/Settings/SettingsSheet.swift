import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

/// App settings, mirroring the macOS settings window's tabs as an iOS
/// navigation list: Account, General, Appearance, Notifications, Machines,
/// Harnesses, MCPs, and Skills. Machine management (the old home-screen
/// machine picker) lives in Machines.
struct SettingsSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CloudAccountScreen()
                    } label: {
                        Label("Account", systemImage: "person.crop.circle")
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
                        MachinesSettingsScreen()
                    } label: {
                        Label("Machines", systemImage: "desktopcomputer")
                    }
                } footer: {
                    Text(
                        "Harnesses, MCPs, skills, and plugins live on each machine — open a machine to manage them."
                    )
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
