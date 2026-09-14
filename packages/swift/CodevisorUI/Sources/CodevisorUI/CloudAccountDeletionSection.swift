import CodevisorCore
import SwiftUI

/// Account deletion shared by Account and Privacy & Data settings.
public struct CloudAccountDeletionSection: View {
  private let cloud: CloudAccountController
  @Binding private var isDeleting: Bool

  public init(cloud: CloudAccountController, isDeleting: Binding<Bool>) {
    self.cloud = cloud
    _isDeleting = isDeleting
  }

  public var body: some View {
    if cloud.state.isSignedIn {
      Section {
        CloudAccountDeletionButton(cloud: cloud, isDeleting: $isDeleting)
      } footer: {
        Text(
          "Permanently delete your Cloud account and disconnect its machines. Files and chats on your machines are kept."
        )
      }
    }
  }
}

struct CloudAccountDeletionButton: View {
  let cloud: CloudAccountController
  @Binding var isDeleting: Bool
  @State private var showsDeleteConfirmation = false
  @State private var errorMessage: String?

  var body: some View {
    Button(isDeleting ? "Deleting Account…" : "Delete Cloud Account", role: .destructive) {
      showsDeleteConfirmation = true
    }
    .foregroundStyle(.red)
    .disabled(isDeleting)
    .alert("Delete Cloud Account?", isPresented: $showsDeleteConfirmation) {
      Button("Delete Cloud Account", role: .destructive) {
        isDeleting = true
        Task {
          await cloud.deleteAccount()
          isDeleting = false
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
