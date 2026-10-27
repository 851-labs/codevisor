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
    HStack {
      PluginAccountLabel(account: account, fallbackName: fallbackName)
      Spacer()
      Menu {
        Button(account.isOAuth ? "Sign In Again…" : "Edit…", action: onEdit)
        Divider()
        Button("Remove…", role: .destructive, action: onRemove)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contextMenu {
      Button(account.isOAuth ? "Sign In Again…" : "Edit…", action: onEdit)
      Button("Remove…", role: .destructive, action: onRemove)
    }
    ForEach(ingress) { PluginIngressRow(ingress: $0) }
  }
}
