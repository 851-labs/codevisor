import CodevisorCore
import CodevisorUI
import SwiftUI

struct AgentRenamePrompt: ViewModifier {
  @Binding var request: ChatSession?
  @Environment(AppEnvironment.self) private var environment
  @State private var name = ""
  @State private var presented: ChatSession?

  func body(content: Content) -> some View {
    content
      .alert(
        "Rename Agent",
        isPresented: Binding(get: { presented != nil }, set: { if !$0 { dismiss() } }),
        presenting: presented
      ) { chat in
        TextField("Name", text: $name)
        Button("Rename") { environment.projectList.renameSession(chat, to: name) }
        Button("Cancel", role: .cancel) {}
      }
      .focusesAlertTextField(when: presented != nil)
      .onChange(of: request?.id) { present(request) }
  }

  private func present(_ chat: ChatSession?) {
    name = chat?.title ?? ""
    presented = chat
  }

  private func dismiss() {
    presented = nil
    request = nil
  }
}
