import CodevisorCore
import CodevisorUI
import SwiftUI

struct CloudAccountScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let dismissSettings: () -> Void
  @State private var showsServer = false
  @State private var showsConnections = false
  @State private var showsEmailSignIn = false
  @State private var isConfirmingDelete = false
  @State private var isConfirmingWithdrawal = false

  var body: some View {
    Form {
      CloudAccountSections(
        cloud: environment.cloud,
        manageConnections: { showsConnections = true },
        configureServer: { showsServer = true },
        signInWithEmail: { showsEmailSignIn = true }
      )
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
    }
    .formStyle(.grouped)
    .navigationTitle("Account")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showsEmailSignIn) { CloudEmailAuthSheet(cloud: environment.cloud) }
    .navigationDestination(isPresented: $showsServer) {
      CloudServerSettings(cloud: environment.cloud)
    }
    .navigationDestination(isPresented: $showsConnections) {
      CloudConnectedAccountsSettings(cloud: environment.cloud)
    }
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
