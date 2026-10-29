import CodevisorCore
import SwiftUI

public struct PluginCatalogBrowser: View {
  @Environment(AppEnvironment.self) private var environment
  let catalog: PluginCatalogModel
  let client: any CodevisorServerClienting
  let installedCatalogIds: Set<String>
  let onAdd: (ServerPluginCatalogEntry) -> Void
  let onOpen: (ServerPluginCatalogEntry) -> Void

  public init(
    catalog: PluginCatalogModel,
    client: any CodevisorServerClienting,
    installedCatalogIds: Set<String>,
    onAdd: @escaping (ServerPluginCatalogEntry) -> Void,
    onOpen: @escaping (ServerPluginCatalogEntry) -> Void
  ) {
    self.catalog = catalog
    self.client = client
    self.installedCatalogIds = installedCatalogIds
    self.onAdd = onAdd
    self.onOpen = onOpen
  }

  public var body: some View {
    let entries = catalog.visibleEntries(hiding: environment.pluginAccess.blockedPublishers)
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if entries.isEmpty {
          PluginCatalogPlaceholder(
            isLoading: catalog.isLoading, isSearching: catalog.isSearching, errorMessage: catalog.errorMessage)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24)], alignment: .leading, spacing: 0) {
          ForEach(entries) { entry in
            PluginCatalogTile(
              entry: entry, client: client, isInstalled: installedCatalogIds.contains(entry.id),
              isInstalling: catalog.installing.contains(entry.id), onAdd: { onAdd(entry) },
              onOpen: { onOpen(entry) })
          }
        }
      }
      .padding(20)
    }
  }
}

private struct PluginCatalogPlaceholder: View {
  let isLoading: Bool
  let isSearching: Bool
  let errorMessage: String?

  var body: some View {
    Group {
      if isLoading {
        ProgressView().controlSize(.small)
      } else {
        Text(errorMessage ?? (isSearching ? "No matching plugins" : "No plugins available"))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 120)
  }
}
