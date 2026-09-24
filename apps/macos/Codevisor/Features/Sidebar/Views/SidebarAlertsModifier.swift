import CodevisorCore
import SwiftUI

/// The sidebar's confirmation and rename alerts, in the same order they were
/// chained on the sidebar content: import, then workspace rename.
struct SidebarAlertsModifier: ViewModifier {
  @Binding var pendingImport: PendingSessionImport?
  @Binding var renamingWorkspace: Workspace?
  @Binding var workspaceRenameTitle: String
  let onImport: (PendingSessionImport) -> Void
  /// Receives the workspace with its new name already applied and pinned.
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
          // An explicit rename pins the name so worktree creation does
          // not replace it.
          var renamed = workspace
          renamed.name = trimmed
          renamed.hasCustomName = true
          onRenameWorkspace(renamed)
        }
        Button("Cancel", role: .cancel) {}
      }
  }

  private func importPromptMessage(for pending: PendingSessionImport) -> String {
    let count = pending.sessions.count
    let chats = count == 1 ? "1 existing agent chat" : "\(count) existing agent chats"
    return
      "Codevisor found \(chats) in “\(pending.project.name)”. Import them to continue those conversations here."
  }
}
