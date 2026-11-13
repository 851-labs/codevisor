import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginAccountFooterButtons: View {
  let actions: PluginAccountActions
  let isWorking: Bool
  let onAdd: () -> Void

  var body: some View {
    if actions.needsFirstAccount {
      Button(actions.spec.addTitle, action: onAdd)
        .buttonStyle(.borderedProminent)
        .disabled(isWorking)
    } else {
      Button(actions.addAnotherTitle, action: onAdd)
        .disabled(isWorking)
    }
  }
}
