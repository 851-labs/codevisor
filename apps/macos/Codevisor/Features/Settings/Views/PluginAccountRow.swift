import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountRow: View {
  let account: ServerPluginAccount
  let fallbackName: String
  let ingress: [ServerPluginIngressURL]
  let actions: PluginAccountActions
  let isWorking: Bool
  let onEdit: () -> Void
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      PluginAccountLabel(account: account, fallbackName: fallbackName)
      Spacer()
      if actions.canRevisit(account) {
        Button(actions.revisitTitle(for: account), action: onEdit)
      }
      Button(actions.rowRemoveTitle, action: onRemove)
    }
    .disabled(isWorking)
    .contextMenu {
      Button(actions.revisitTitle(for: account), action: onEdit)
      Button(actions.rowRemoveTitle, role: .destructive, action: onRemove)
    }
    ForEach(ingress) { PluginIngressRow(ingress: $0) }
  }
}
