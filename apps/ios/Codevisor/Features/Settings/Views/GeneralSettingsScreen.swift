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
  @State private var isDeletingCloudAccount = false

  var body: some View {
    List {
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
