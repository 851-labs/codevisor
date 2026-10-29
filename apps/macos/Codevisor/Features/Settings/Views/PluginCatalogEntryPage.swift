import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogEntryPage: View {
  @State private var installTarget: ServerPluginCatalogEntry?
  let entryId: String
  let catalog: PluginCatalogModel
  let plugins: PluginSettingsModel
  let client: any CodevisorServerClienting

  var body: some View {
    if let entry = catalog.entries.first(where: { $0.id == entryId }) {
      PluginCatalogDetail(
        entry: entry, client: client, isInstalled: plugins.fleet.installedCatalogIds.contains(entryId),
        isInstalling: catalog.installing.contains(entryId)
      ) {
        installTarget = entry
      }
      .sheet(item: $installTarget) { entry in
        PluginCatalogInstallSheet(entry: entry, catalog: catalog, plugins: plugins)
      }
      .pluginConnectErrorAlert(plugins.fleet)
    } else {
      ContentUnavailableView("Plugin Unavailable", systemImage: "puzzlepiece.extension")
    }
  }
}
