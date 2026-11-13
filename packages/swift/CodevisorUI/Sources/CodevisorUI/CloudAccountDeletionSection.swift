import CodevisorCore
import SwiftUI

public struct CloudAccountDeletionSection: View {
  private let cloud: CloudAccountController

  public init(cloud: CloudAccountController) {
    self.cloud = cloud
  }

  public var body: some View {
    if cloud.state.isSignedIn {
      Section {
        CloudAccountDeletionButton(cloud: cloud)
      } footer: {
        Text(
          "Permanently delete your Cloud account and disconnect its machines. Files and chats on your machines are kept."
        )
      }
    }
  }
}

public struct CloudAccountDeletionButton: View {
  private let cloud: CloudAccountController
  private let title: String
  private let deletingTitle: String
  @State private var showsDeleteConfirmation = false
  @State private var errorMessage: String?

  public init(
    cloud: CloudAccountController,
    title: String = "Delete Cloud Account",
    deletingTitle: String = "Deleting Account…"
  ) {
    self.cloud = cloud
    self.title = title
    self.deletingTitle = deletingTitle
  }

  public var body: some View {
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
