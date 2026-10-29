import CodevisorUI
import SwiftUI

extension View {
  func pluginErrorsAlert(_ model: McpGlobalModel, includesActionErrors: Bool = true) -> some View {
    modifier(PluginErrorsAlert(model: model, includesActionErrors: includesActionErrors))
  }
}

private struct PluginErrorsAlert: ViewModifier {
  let model: McpGlobalModel
  let includesActionErrors: Bool

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
    let actionError = includesActionErrors ? model.actionError : nil
    return actionError ?? model.connectError
  }

  private func dismiss() {
    if includesActionErrors { model.actionError = nil }
    model.connectError = nil
  }
}
