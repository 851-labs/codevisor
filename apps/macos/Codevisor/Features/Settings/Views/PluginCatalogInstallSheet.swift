import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogInstallSheet: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: ServerPluginCatalogEntry
  let catalog: PluginCatalogModel
  let plugins: PluginSettingsModel
  let client: any CodevisorServerClienting

  var body: some View {
    PluginConnectSheet(entry: entry, client: client, host: host)
      .environment(environment)
  }

  private var host: PluginConnectHost {
    PluginConnectHost(
      install: { values, authType in
        try await catalog.install(entry, values: values, authType: authType, access: environment.pluginAccess)
      },
      didInstall: { plugins.didInstall($0, in: environment) },
      signIn: { server, browser in
        await plugins.fleet.connect(
          serverId: server.id, on: CodevisorMachine.local.id, in: environment, browser: browser)
      },
      signInFailed: { plugins.fleet.connectError = $0 }
    )
  }
}
