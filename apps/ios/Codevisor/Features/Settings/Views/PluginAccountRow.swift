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

  var body: some View {
    PluginAccountLabel(account: account, fallbackName: fallbackName)
      .swipeActions {
        Button(actions.removeTitle, role: .destructive, action: onRemove)
      }
      .contextMenu {
        Button(actions.revisitTitle(for: account), systemImage: "pencil", action: onEdit)
        Button(actions.removeTitle, systemImage: "trash", role: .destructive, action: onRemove)
      }
    ForEach(ingress) { PluginIngressRow(ingress: $0) }
  }
}
