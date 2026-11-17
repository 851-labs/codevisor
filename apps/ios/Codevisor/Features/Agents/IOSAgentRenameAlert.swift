import CodevisorCore
import SwiftUI

struct IOSAgentRenameAlert: ViewModifier {
  @Binding var renamingAgent: ChatSession?
  @Binding var title: String
  @Environment(AppEnvironment.self) private var environment

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename Agent",
        isPresented: Binding(get: { renamingAgent != nil }, set: { if !$0 { renamingAgent = nil } }),
        presenting: renamingAgent
      ) { chat in
        TextField("Name", text: $title)
        Button("Rename") { environment.projectList.renameSession(chat, to: title) }
        Button("Cancel", role: .cancel) {}
      }
  }
}
