import CodevisorCore
import SwiftUI

struct PluginSetupConnectSheet: ViewModifier {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @Bindable var model: PluginSetupModel
  let client: any CodevisorServerClienting

  func body(content: Content) -> some View {
    content.sheet(item: $model.connecting, onDismiss: finish) { target in
      if let environment {
        PluginConnectSheet(
          entry: target.entry, installed: target.installed, client: client,
          host: host(for: target, in: environment)
        )
        .environment(environment)
      }
    }
  }

  private func host(for target: PluginConnectTarget, in environment: AppEnvironment) -> PluginConnectHost {
    model.connectHost { values, authType in
      try await PluginCatalogModel(client: client).install(
        target.entry, values: values, authType: authType, access: environment.pluginAccess)
    }
  }

  private func finish() {
    Task { await model.connectSheetDismissed() }
  }
}
