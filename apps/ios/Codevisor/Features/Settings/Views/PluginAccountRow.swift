import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountRow: View {
  let account: ServerPluginAccount
  let fallbackName: String
  let ingress: [ServerPluginIngressURL]
  let actions: PluginAccountActions
  let onEdit: () -> Void
  let onRemove: () -> Void
  @State private var confirmsRemoval = false

  var body: some View {
    PluginAccountLabel(account: account, fallbackName: fallbackName)
      .swipeActions {
        ConfirmingDestructiveButton(actions.removeTitle) { confirmsRemoval = true }
        if actions.canRevisit(account) {
          Button(actions.revisitTitle(for: account), action: onEdit)
        }
      }
      .contextMenu {
        Button(actions.revisitTitle(for: account), systemImage: "pencil", action: onEdit)
        Button(actions.removeTitle, systemImage: "trash", role: .destructive) { confirmsRemoval = true }
      }
      .modifier(
        PluginAccountRemovalDialog(
          account: account, actions: actions, isPresented: $confirmsRemoval, onRemove: onRemove)
      )
    ForEach(ingress) { PluginIngressRow(ingress: $0) }
  }
}
