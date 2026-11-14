import CodevisorCore
import CodevisorUI
import SwiftUI

struct DataDeletionSection: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var isConfirmingDeletion = false

  var body: some View {
    Section("Data") {
      SettingsDeletionRow(
        title: "Delete all data",
        description: "Removes all projects, chats, and settings, then restarts setup."
      ) {
        Button("Delete…", role: .destructive) {
          isConfirmingDeletion = true
        }
      }
      .confirmationDialog(
        "Delete all Codevisor data?",
        isPresented: $isConfirmingDeletion,
        titleVisibility: .visible
      ) {
        Button("Delete everything", role: .destructive) {
          environment.deleteAllData()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This can't be undone. You'll be taken back through setup.")
      }
    }
  }
}
