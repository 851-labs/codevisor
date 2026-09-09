import CodevisorCore
import SwiftUI

/// The tab a rename alert is editing.
struct HomeTabRenameRequest: Identifiable, Equatable {
  let workspaceId: UUID
  let tabId: UUID
  var id: UUID { tabId }
}

/// The sidebar's rename alerts, chained in one place so the screen body
/// stays within the size ratchet.
struct HomeSidebarAlerts: ViewModifier {
  @Binding var renamingWorkspace: Workspace?
  @Binding var workspaceRenameTitle: String
  @Binding var renamingTab: HomeTabRenameRequest?
  @Binding var tabRenameTitle: String
  /// Receives the workspace with its new name already applied and pinned.
  let onRenameWorkspace: (Workspace) -> Void
  let onRenameTab: (HomeTabRenameRequest, String) -> Void

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
          // An explicit rename pins the name so worktree creation does
          // not replace it.
          var renamed = workspace
          renamed.name = trimmed
          renamed.hasCustomName = true
          onRenameWorkspace(renamed)
        }
        Button("Cancel", role: .cancel) {}
      }
      .alert(
        "Rename Tab",
        isPresented: Binding(
          get: { renamingTab != nil },
          set: { if !$0 { renamingTab = nil } }
        ),
        presenting: renamingTab
      ) { request in
        TextField("Title", text: $tabRenameTitle)
        Button("Rename") {
          onRenameTab(request, tabRenameTitle)
        }
        Button("Cancel", role: .cancel) {}
      }
  }
}
