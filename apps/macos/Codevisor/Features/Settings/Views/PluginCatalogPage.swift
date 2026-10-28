import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogPage: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var installTarget: ServerPluginCatalogEntry?
  let catalog: PluginCatalogModel
  let plugins: PluginSettingsModel
  let client: any CodevisorServerClienting

  var body: some View {
    PluginCatalogBrowser(
      catalog: catalog, client: client, installedCatalogIds: plugins.fleet.installedCatalogIds,
      onAdd: { installTarget = $0 }, onOpen: showDetail
    )
    .navigationTitle("Browse Plugins")
    .searchable(text: query, placement: .toolbar, prompt: "Search plugins")
    .task { await catalog.load() }
    .sheet(item: $installTarget) { entry in
      PluginCatalogInstallSheet(entry: entry, catalog: catalog, plugins: plugins)
    }
  }

  private var query: Binding<String> {
    Binding(get: { catalog.query }, set: { catalog.search($0) })
  }

  private func showDetail(_ entry: ServerPluginCatalogEntry) {
    SettingsRouter.shared.panePath.append(.pluginCatalogEntry(entry.id))
  }
}
