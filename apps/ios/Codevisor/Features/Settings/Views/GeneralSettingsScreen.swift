import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

// MARK: - General

struct GeneralSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDelete = false

    var body: some View {
        List {
            Section {
                Toggle(
                    "Share usage analytics",
                    isOn: Binding(
                        get: { environment.settings.shareAnalytics },
                        set: { environment.setShareAnalytics($0) }
                    )
                )
                Toggle(
                    "Send crash and error reports",
                    isOn: Binding(
                        get: { environment.settings.shareCrashReports },
                        set: { environment.setShareCrashReports($0) }
                    )
                )
            } header: {
                Text("Privacy")
            } footer: {
                Text("Helps improve Codevisor. Never includes your code or conversations.")
            }
            Section {
                Button("Delete All Data", role: .destructive) {
                    isConfirmingDelete = true
                }
            } footer: {
                Text("Removes this device's paired machines and local state. Nothing on your machines is changed.")
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete all local data?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                environment.deleteAllData()
            }
        }
    }
}
