import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarAlertsModifier: ViewModifier {
  @Binding var pendingImport: PendingSessionImport?
  @Binding var renamingWorkspace: Workspace?
  @Binding var workspaceRenameTitle: String
  let onImport: (PendingSessionImport) -> Void
  let onRenameWorkspace: (Workspace) -> Void

  func body(content: Content) -> some View {
    content
      .alert(
        "Import Existing Chats?",
        isPresented: Binding(
          get: { pendingImport != nil },
          set: { if !$0 { pendingImport = nil } }
        ),
        presenting: pendingImport
      ) { pending in
        Button("Import") {
          onImport(pending)
        }
        Button("Not Now", role: .cancel) {}
      } message: { pending in
        Text(importPromptMessage(for: pending))
      }
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
      .focusesAlertTextField(when: renamingWorkspace != nil)
  }

  private func importPromptMessage(for pending: PendingSessionImport) -> String {
    let count = pending.sessions.count
    let chats = count == 1 ? "1 existing agent chat" : "\(count) existing agent chats"
    return
      "Codevisor found \(chats) in “\(pending.project.name)”. Import them to continue those conversations here."
  }
}
