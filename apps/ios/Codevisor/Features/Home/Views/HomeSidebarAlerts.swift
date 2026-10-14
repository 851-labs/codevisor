import CodevisorCore
import SwiftUI

struct HomeTabRenameRequest: Identifiable, Equatable {
  let workspaceId: UUID
  let tabId: UUID
  var chatSessionId: UUID? = nil
  var id: UUID { tabId }
}

struct HomeSidebarAlerts: ViewModifier {
  @Binding var renamingWorkspace: Workspace?
  @Binding var workspaceRenameTitle: String
  @Binding var renamingTab: HomeTabRenameRequest?
  @Binding var tabRenameTitle: String
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
