import AuthenticationServices
import CodevisorCore
import CodevisorUI
import SwiftUI
import os

struct GeneralSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let dismissSettings: () -> Void
  @State private var isConfirmingDelete = false
  @State private var isConfirmingWithdrawal = false
  @State private var isDeletingCloudAccount = false

  var body: some View {
    List {
      Section {
        Button("Withdraw AI Consent", role: .destructive) {
          isConfirmingWithdrawal = true
        }
        .foregroundStyle(.red)
        .accessibilityIdentifier("privacy.withdrawAIConsent")
      } footer: {
        Text(
          "Revokes consent to share data with AI providers, clears this device's Codevisor data, and signs you out."
        )
      }
      Section {
        Button("Delete Device Data", role: .destructive) {
          isConfirmingDelete = true
        }
        .foregroundStyle(.red)
      } footer: {
        Text(
          "Removes this device's paired machines, Codevisor Cloud sign-in, and local state. Nothing on your machines is changed."
        )
      }
      CloudAccountDeletionSection(cloud: environment.cloud, isDeleting: $isDeletingCloudAccount)
    }
    .disabled(isDeletingCloudAccount)
    .navigationTitle("Privacy & Data")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Withdraw AI Consent?", isPresented: $isConfirmingWithdrawal) {
      Button("Withdraw AI Consent", role: .destructive) {
        environment.deleteAllData()
        dismissSettings()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This deletes all Codevisor data from this device and signs you out. You’ll need to complete setup again.")
    }
    .alert("Delete Device Data?", isPresented: $isConfirmingDelete) {
      Button("Delete Device Data", role: .destructive) {
        environment.deleteAllData()
        dismissSettings()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This can't be undone. You'll be taken back through setup.")
    }
  }
}
