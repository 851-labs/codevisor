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
  let machineId: String
  let client: any CodevisorServerClienting
  let fleet: McpGlobalModel
  let onInstalled: (ServerMcpServer) -> Void

  init(
    machineId: String,
    client: any CodevisorServerClienting,
    fleet: McpGlobalModel,
    onInstalled: @escaping (ServerMcpServer) -> Void
  ) {
    _catalog = State(initialValue: PluginCatalogModel(client: client))
    self.machineId = machineId
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
        PluginConnectSheet(entry: entry, client: client, host: host(for: entry))
          .environment(environment)
      }
    }
  }

  private func host(for entry: ServerPluginCatalogEntry) -> PluginConnectHost {
    fleet.connectHost(
      on: machineId, in: environment,
      install: { values, authType in
        try await catalog.install(entry, values: values, authType: authType, access: environment.pluginAccess)
      },
      didInstall: { server in
        onInstalled(server)
        dismiss()
      }
    )
  }
}
