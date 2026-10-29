import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountRemovalDialog: ViewModifier {
  let actions: PluginAccountActions
  @Binding var candidates: [ServerPluginAccount]
  let onRemove: (ServerPluginAccount) -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(
      actions.removalPrompt(for: candidates),
      isPresented: isPresented,
      titleVisibility: .visible
    ) {
      ForEach(candidates) { account in
        Button(actions.removalButtonTitle(for: account, among: candidates), role: .destructive) {
          onRemove(account)
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  private var isPresented: Binding<Bool> {
    Binding(get: { !candidates.isEmpty }, set: { if !$0 { candidates = [] } })
  }
}

extension View {
  func pluginAccountRemovalDialog(
    actions: PluginAccountActions,
    candidates: Binding<[ServerPluginAccount]>,
    onRemove: @escaping (ServerPluginAccount) -> Void
  ) -> some View {
    modifier(PluginAccountRemovalDialog(actions: actions, candidates: candidates, onRemove: onRemove))
  }
}
