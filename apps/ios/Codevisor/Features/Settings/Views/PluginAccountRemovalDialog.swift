import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountRemovalDialog: ViewModifier {
  let account: ServerPluginAccount
  let actions: PluginAccountActions
  @Binding var isPresented: Bool
  let onRemove: () -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(
      actions.removalPrompt(for: account), isPresented: $isPresented, titleVisibility: .visible
    ) {
      Button(actions.removeTitle, role: .destructive, action: onRemove)
      Button("Cancel", role: .cancel) {}
    }
  }
}
