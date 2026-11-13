import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountRemovalDialog: ViewModifier {
  let actions: PluginAccountActions
  @Binding var removing: ServerPluginAccount?
  let onRemove: (ServerPluginAccount) -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(
      removing.map(actions.removalPrompt(for:)) ?? "",
      isPresented: isPresented,
      titleVisibility: .visible,
      presenting: removing
    ) { account in
      Button(actions.removeTitle, role: .destructive) { onRemove(account) }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var isPresented: Binding<Bool> {
    Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
  }
}

extension View {
  func pluginAccountRemovalDialog(
    actions: PluginAccountActions,
    removing: Binding<ServerPluginAccount?>,
    onRemove: @escaping (ServerPluginAccount) -> Void
  ) -> some View {
    modifier(PluginAccountRemovalDialog(actions: actions, removing: removing, onRemove: onRemove))
  }
}
