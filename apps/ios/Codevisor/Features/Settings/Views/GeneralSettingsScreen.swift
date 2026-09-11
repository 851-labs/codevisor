import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import os

// MARK: - Privacy & Data

struct GeneralSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  /// Closes the ENTIRE settings sheet (not just this pushed screen) once a
  /// delete is confirmed — the app is back at first launch underneath.
  let dismissSettings: () -> Void
  @State private var isConfirmingDelete = false
  @State private var isConfirmingConsentWithdrawal = false
  @ClientPreference(AIDataSharingConsent.preferenceKey, default: 0)
  private var aiDataSharingConsentVersion

  var body: some View {
    List {
      Section {
        NavigationLink("AI data sharing") {
          AIDataSharingConsentScreen()
        }
        Link("Privacy Policy", destination: AIDataSharingConsent.privacyPolicyURL)
        if aiDataSharingConsentVersion == AIDataSharingConsent.currentVersion {
          Button("Withdraw AI consent", role: .destructive) {
            isConfirmingConsentWithdrawal = true
          }
          .accessibilityIdentifier("aiConsent.withdraw")
        }
      } header: {
        Text("AI Data Sharing")
      } footer: {
        Text(
          "Your permission applies to AI use from this device. Usage analytics and crash reports are separate choices.")
      }
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
    .navigationTitle("Privacy & Data")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Withdraw AI consent?", isPresented: $isConfirmingConsentWithdrawal) {
      Button("Withdraw Consent", role: .destructive) {
        aiDataSharingConsentVersion = 0
        dismissSettings()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "You'll need to agree again before using AI from this device. Tasks already running on your machines will continue."
      )
    }
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
