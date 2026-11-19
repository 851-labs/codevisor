import CodevisorCore
import CodevisorUI
import SwiftUI

struct DataDeletionSection: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var isConfirmingDeletion = false

  var body: some View {
    Section("Data") {
      SettingsDeletionRow(
        title: "Delete app data",
        description:
          "Removes everything this app stores on this Mac, including caches, sign-in, and settings, then restarts Codevisor. Projects and chats on your machines aren't changed."
      ) {
        Button("Delete…", role: .destructive) {
          isConfirmingDeletion = true
        }
      }
      .confirmationDialog(
        "Delete Codevisor's app data on this Mac?",
        isPresented: $isConfirmingDeletion,
        titleVisibility: .visible
      ) {
        Button("Delete and Restart", role: .destructive) {
          environment.deleteAllData()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This can't be undone. Codevisor will restart signed out, with default settings.")
      }
    }
  }
}
