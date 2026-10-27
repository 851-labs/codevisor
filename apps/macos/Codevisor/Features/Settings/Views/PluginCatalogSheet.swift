import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginCatalogSheet: View {
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
    VStack(spacing: 0) {
      PluginCatalogSearchHeader(query: $query)
      Form {
        PluginCatalogList(catalog: catalog, installedCatalogIds: installedCatalogIds) { installTarget = $0 }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 560, height: 520)
    .task { await catalog.load() }
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

private struct PluginCatalogSearchHeader: View {
  @Binding var query: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Browse Plugins").font(.headline)
      TextField("Search Plugins", text: $query, prompt: Text("Search plugins and the MCP Registry"))
        .textFieldStyle(.roundedBorder)
    }
    .padding(.horizontal, 20)
    .padding(.top, 18)
  }
}
