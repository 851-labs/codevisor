import CodevisorUI
import SwiftUI

extension View {
  func pluginConnectErrorAlert(_ model: McpGlobalModel) -> some View {
    modifier(PluginConnectErrorAlert(model: model))
  }
}

private struct PluginConnectErrorAlert: ViewModifier {
  let model: McpGlobalModel

  func body(content: Content) -> some View {
    content.alert(
      "Couldn’t Connect",
      isPresented: Binding(
        get: { model.connectError != nil }, set: { if !$0 { model.connectError = nil } })
    ) {
      Button("OK", role: .cancel) { model.connectError = nil }
    } message: {
      Text(model.connectError ?? "")
    }
  }
}
