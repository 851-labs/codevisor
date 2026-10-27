import CodevisorCore
import SwiftUI

public struct PluginCatalogList: View {
  @Environment(AppEnvironment.self) private var environment
  let catalog: PluginCatalogModel
  let installedCatalogIds: Set<String>
  let onInstall: (ServerPluginCatalogEntry) -> Void

  public init(
    catalog: PluginCatalogModel,
    installedCatalogIds: Set<String>,
    onInstall: @escaping (ServerPluginCatalogEntry) -> Void
  ) {
    self.catalog = catalog
    self.installedCatalogIds = installedCatalogIds
    self.onInstall = onInstall
  }

  public var body: some View {
    let sections = catalog.sections(hiding: environment.pluginAccess.blockedPublishers)
    if sections.isEmpty {
      Section {
        PluginCatalogPlaceholder(isLoading: catalog.isLoading, isSearching: catalog.isSearching)
      } footer: {
        if let message = catalog.errorMessage { Text(message) }
      }
    }
    ForEach(sections) { section in
      Section(section.title) {
        ForEach(section.entries) { entry in
          PluginCatalogRow(
            entry: entry,
            isInstalled: installedCatalogIds.contains(entry.id),
            isInstalling: catalog.installing.contains(entry.id)
          ) {
            onInstall(entry)
          }
        }
      }
    }
  }
}

private struct PluginCatalogPlaceholder: View {
  let isLoading: Bool
  let isSearching: Bool

  var body: some View {
    if isLoading {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity)
    } else {
      Text(isSearching ? "No matching plugins" : "No plugins available").foregroundStyle(.secondary)
    }
  }
}
