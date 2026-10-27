import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountRow: View {
  let account: ServerPluginAccount
  let fallbackName: String
  let ingress: [ServerPluginIngressURL]
  let onEdit: () -> Void
  let onRemove: () -> Void

  var body: some View {
    Button(action: onEdit) {
      PluginAccountLabel(account: account, fallbackName: fallbackName)
    }
    .tint(.primary)
    .swipeActions {
      Button("Remove", role: .destructive, action: onRemove)
    }
    .contextMenu {
      Button(account.isOAuth ? "Sign In Again" : "Edit", systemImage: "pencil", action: onEdit)
      Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
    }
    ForEach(ingress) { PluginIngressRow(ingress: $0) }
  }
}
