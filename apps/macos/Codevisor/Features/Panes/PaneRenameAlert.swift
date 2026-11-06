import CodevisorCore
import CodevisorUI
import SwiftUI

struct PaneRenameAlert: ViewModifier {
  let kind: PaneKind?
  @Binding var isPresented: Bool
  @Binding var text: String
  let onRename: (String) -> Void

  func body(content: Content) -> some View {
    content
      .alert(title, isPresented: $isPresented) {
        TextField("Name", text: $text)
        Button("Cancel", role: .cancel) {}
        Button("Rename") { onRename(text) }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .focusesAlertTextField(when: isPresented)
  }

  private var title: String {
    switch kind {
    case .chat: "Rename Chat"
    case .terminal: "Rename Terminal"
    case .newTab, .plugin, .document, .browser, .screenSharing, .subagent, .review, .simulator, .transcript,
      .childAgent, .none:
      "Rename Pane"
    }
  }
}
