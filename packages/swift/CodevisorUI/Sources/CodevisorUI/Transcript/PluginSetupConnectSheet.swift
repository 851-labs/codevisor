import CodevisorCore
import SwiftUI

struct PluginSetupConnectSheet: ViewModifier {
  @Environment(AppEnvironment.self) private var environment: AppEnvironment?
  @Bindable var model: PluginSetupModel
  let client: any CodevisorServerClienting

  func body(content: Content) -> some View {
    #if os(macOS)
      content.sheet(item: $model.connecting, onDismiss: finish) { target in
        if let environment {
          PluginConnectSheet(
            entry: target.entry, installed: target.installed, client: client,
            host: host(for: target, in: environment)
          )
          .environment(environment)
        }
      }
    #else
      content
    #endif
  }

  #if os(macOS)
    private func host(for target: PluginConnectTarget, in environment: AppEnvironment) -> PluginConnectHost {
      PluginConnectHost(
        install: { values, authType in
          try await PluginCatalogModel(client: client).install(
            target.entry, values: values, authType: authType, access: environment.pluginAccess)
        },
        didInstall: { model.didInstall($0) },
        signIn: { server, browser in await model.signIn(to: server, browser: browser) },
        signInFailed: { model.errorMessage = $0 }
      )
    }

    private func finish() {
      Task { await model.connectSheetDismissed() }
    }
  #endif
}
