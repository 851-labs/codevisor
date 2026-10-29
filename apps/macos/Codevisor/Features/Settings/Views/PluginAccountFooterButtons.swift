import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountFooterButtons: View {
  let actions: PluginAccountActions
  let isWorking: Bool
  let onAdd: () -> Void
  let onEdit: (ServerPluginAccount) -> Void
  let onRemove: () -> Void

  var body: some View {
    if actions.needsFirstAccount {
      Button(actions.spec.addTitle, action: onAdd)
        .buttonStyle(.borderedProminent)
        .disabled(isWorking)
    } else {
      if let account = actions.revisitTarget {
        Button(actions.revisitTitle(for: account)) { onEdit(account) }
          .disabled(isWorking)
      }
      Button(actions.addAnotherTitle, action: onAdd)
        .disabled(isWorking)
      Button("\(actions.removeTitle)…", action: onRemove)
        .disabled(isWorking)
    }
  }
}
