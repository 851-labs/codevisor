import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var catalog: PluginCatalogModel
  @State private var query = ""
  @State private var installTarget: ServerPluginCatalogEntry?
  let installedCatalogIds: Set<String>
  let onInstalled: (ServerMcpServer) async -> Void

  init(
    client: any CodevisorServerClienting,
    installedCatalogIds: Set<String>,
    onInstalled: @escaping (ServerMcpServer) async -> Void
  ) {
    _catalog = State(initialValue: PluginCatalogModel(client: client))
    self.installedCatalogIds = installedCatalogIds
    self.onInstalled = onInstalled
  }

  var body: some View {
    NavigationStack {
      List {
        PluginCatalogList(catalog: catalog, installedCatalogIds: installedCatalogIds) { installTarget = $0 }
      }
      .navigationTitle("Browse Plugins")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $query, prompt: "Plugins and MCP Registry")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
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
