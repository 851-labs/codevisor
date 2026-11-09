import CodevisorUI
import SwiftUI

extension View {
  func pluginErrorsAlert(_ model: McpGlobalModel) -> some View {
    modifier(PluginErrorsAlert(model: model))
  }
}

private struct PluginErrorsAlert: ViewModifier {
  let model: McpGlobalModel

  func body(content: Content) -> some View {
    content.alert(
      "Couldn’t update plugins",
      isPresented: Binding(get: { message != nil }, set: { if !$0 { dismiss() } })
    ) {
      Button("OK", role: .cancel) { dismiss() }
    } message: {
      Text(message ?? "")
    }
  }

  private var message: String? {
    model.actionError ?? model.connectError
  }

  private func dismiss() {
    model.actionError = nil
    model.connectError = nil
  }
}
