import CodevisorCore
import CodevisorUI
import SwiftUI

struct AddToChatComposerFocus: ViewModifier {
  let controller: SessionController
  let focus: TerminalFocusController
  @Environment(WorkspaceActivity.self) private var activity: WorkspaceActivity?

  func body(content: Content) -> some View {
    content.onChange(of: ChatSignal(controller.addToChatSignal, of: controller)) { old, new in
      guard old.isSameChat(as: new), activity?.isActive ?? true,
        let chatId = controller.serverSession?.id
      else { return }
      focus.focusComposerAfterAddToChat(forChat: chatId)
    }
  }
}

extension View {
  func focusesComposerAfterAddToChat(_ controller: SessionController, focus: TerminalFocusController) -> some View {
    modifier(AddToChatComposerFocus(controller: controller, focus: focus))
  }
}
