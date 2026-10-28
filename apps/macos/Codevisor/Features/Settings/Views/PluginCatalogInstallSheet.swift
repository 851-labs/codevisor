import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogInstallSheet: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: ServerPluginCatalogEntry
  let catalog: PluginCatalogModel
  let plugins: PluginSettingsModel

  var body: some View {
    PluginInstallSheet(entry: entry) { values in
      let installed = try await catalog.install(entry, values: values, access: environment.pluginAccess)
      await plugins.didInstall(installed, in: environment)
    }
    .environment(environment)
  }
}
