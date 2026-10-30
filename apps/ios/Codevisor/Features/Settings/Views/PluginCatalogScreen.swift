import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var catalog: PluginCatalogModel
  @State private var query = ""
  @State private var installTarget: ServerPluginCatalogEntry?
  @State private var openedPlugin: String?
  let client: any CodevisorServerClienting
  let fleet: McpGlobalModel
  let onInstalled: (ServerMcpServer) -> Void

  init(
    client: any CodevisorServerClienting,
    fleet: McpGlobalModel,
    onInstalled: @escaping (ServerMcpServer) -> Void
  ) {
    _catalog = State(initialValue: PluginCatalogModel(client: client))
    self.client = client
    self.fleet = fleet
    self.onInstalled = onInstalled
  }

  var body: some View {
    NavigationStack {
      PluginCatalogBrowser(
        catalog: catalog, client: client, installedCatalogIds: fleet.installedCatalogIds,
        onAdd: { installTarget = $0 }, onOpen: { openedPlugin = fleet.entry(installedFrom: $0.id)?.name }
      )
      .navigationTitle("Plugins")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "Search plugins")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .navigationDestination(item: $openedPlugin) { name in
        McpPluginDetailScreen(entryName: name, model: fleet)
      }
      .task { await catalog.load() }
      .task { try? await environment.pluginAccess.refresh() }
      .onChange(of: query) { _, text in catalog.search(text) }
      .sheet(item: $installTarget) { entry in
        PluginInstallSheet(entry: entry, client: client) { values in
          onInstalled(try await catalog.install(entry, values: values, access: environment.pluginAccess))
        }
        .environment(environment)
      }
    }
  }
}
