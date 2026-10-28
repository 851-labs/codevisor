import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var catalog: PluginCatalogModel
  @State private var query = ""
  @State private var installTarget: ServerPluginCatalogEntry?
  @State private var detailId: String?
  let client: any CodevisorServerClienting
  let installedCatalogIds: Set<String>
  let onInstalled: (ServerMcpServer) async -> Void

  init(
    client: any CodevisorServerClienting,
    installedCatalogIds: Set<String>,
    onInstalled: @escaping (ServerMcpServer) async -> Void
  ) {
    _catalog = State(initialValue: PluginCatalogModel(client: client))
    self.client = client
    self.installedCatalogIds = installedCatalogIds
    self.onInstalled = onInstalled
  }

  var body: some View {
    NavigationStack {
      PluginCatalogBrowser(
        catalog: catalog, client: client, installedCatalogIds: installedCatalogIds,
        onAdd: { installTarget = $0 }, onOpen: { detailId = $0.id }
      )
      .navigationTitle("Plugins")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "Search plugins")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .navigationDestination(item: $detailId) { id in
        if let entry = catalog.entries.first(where: { $0.id == id }) {
          PluginCatalogDetail(
            entry: entry, client: client, isInstalled: installedCatalogIds.contains(id),
            isInstalling: catalog.installing.contains(id)
          ) {
            installTarget = entry
          }
        }
      }
      .task { await catalog.load() }
      .task { try? await environment.pluginAccess.refresh() }
      .onChange(of: query) { _, text in catalog.search(text) }
      .sheet(item: $installTarget) { entry in
        PluginInstallSheet(entry: entry) { values in
          let installed = try await catalog.install(entry, values: values, access: environment.pluginAccess)
          await onInstalled(installed)
        }
        .environment(environment)
      }
    }
  }
}
