import CodevisorCore
import SwiftUI

struct CloudAccountDeletionSection: View {
  let cloud: CloudAccountController

  var body: some View {
    if cloud.state.isSignedIn {
      #if os(macOS)
        Section {
          SettingsDeletionRow(
            title: "Delete cloud account",
            description: "Permanently deletes your account and disconnects your machines."
          ) {
            CloudAccountDeletionButton(cloud: cloud, title: "Delete…", deletingTitle: "Deleting…")
          }
        }
      #else
        Section {
          CloudAccountDeletionButton(cloud: cloud, title: "Delete Cloud Account", deletingTitle: "Deleting Account…")
        } footer: {
          Text(
            "Permanently delete your Cloud account and disconnect its machines. Files and chats on your machines are kept."
          )
        }
      #endif
    }
  }
}

struct CloudAccountDeletionButton: View {
  let cloud: CloudAccountController
  let title: String
  let deletingTitle: String
  @State private var showsDeleteConfirmation = false
  @State private var errorMessage: String?

  var body: some View {
    Button(cloud.isDeletingAccount ? deletingTitle : title, role: .destructive) {
      showsDeleteConfirmation = true
    }
    #if os(iOS)
      .foregroundStyle(.red)
    #endif
    .disabled(cloud.isDeletingAccount)
    .alert("Delete Cloud Account?", isPresented: $showsDeleteConfirmation) {
      Button("Delete Cloud Account", role: .destructive) {
        Task {
          await cloud.deleteAccount()
          errorMessage = cloud.lastError
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes your Cloud account and disconnects all your machines. This cannot be undone.")
    }
    .alert("Account", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }
}
