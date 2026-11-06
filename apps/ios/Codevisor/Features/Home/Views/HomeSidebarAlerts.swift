import CodevisorCore
import SwiftUI

struct HomeSidebarAlerts: ViewModifier {
  @Binding var renamingWorkspace: Workspace?
  @Binding var workspaceRenameTitle: String
  let onRenameWorkspace: (Workspace) -> Void

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename Workspace",
        isPresented: Binding(
          get: { renamingWorkspace != nil },
          set: { if !$0 { renamingWorkspace = nil } }
        ),
        presenting: renamingWorkspace
      ) { workspace in
        TextField("Name", text: $workspaceRenameTitle)
        Button("Rename") {
          let trimmed = workspaceRenameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return }
          var renamed = workspace
          renamed.name = trimmed
          renamed.hasCustomName = true
          onRenameWorkspace(renamed)
        }
        Button("Cancel", role: .cancel) {}
      }
  }
}
