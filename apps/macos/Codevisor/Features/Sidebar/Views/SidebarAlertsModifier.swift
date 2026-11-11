import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarAlertsModifier: ViewModifier {
  @Binding var pendingImport: PendingSessionImport?
  let onImport: (PendingSessionImport) -> Void

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
  }

  private func importPromptMessage(for pending: PendingSessionImport) -> String {
    let count = pending.sessions.count
    let chats = count == 1 ? "1 existing agent chat" : "\(count) existing agent chats"
    return
      "Codevisor found \(chats) in “\(pending.project.name)”. Import them to continue those conversations here."
  }
}
