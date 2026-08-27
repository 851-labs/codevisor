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
    /// Closes the ENTIRE settings sheet (not just this pushed screen) once a
    /// delete is confirmed — the app is back at first launch underneath.
    let dismissSettings: () -> Void
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
                Text(
                    "Removes this device's paired machines, Codevisor Cloud sign-in, and local state. Nothing on your machines is changed."
                )
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete all local data?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                environment.deleteAllData()
                dismissSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. You'll be taken back through setup.")
        }
    }
}
