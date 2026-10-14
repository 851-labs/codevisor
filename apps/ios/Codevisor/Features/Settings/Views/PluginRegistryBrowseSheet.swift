import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginRegistryBrowseSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  let fetchRegistry: () async throws -> ServerPluginRegistryIndex
  let installedPlugins: [ServerPluginSummary]

  private var installedIds: Set<String> { Set(installedPlugins.map(\.id)) }
  let onInstall: (ServerPluginRegistryEntry) -> Void

  @State private var entries: [ServerPluginRegistryEntry]?
  @State private var errorMessage: String?
  @State private var query = ""

  private var filtered: [ServerPluginRegistryEntry] {
    PluginRegistryBrowsing.filter(entries ?? [], query: query)
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Browse Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }
          }
        }
        .navigationDestination(for: ServerPluginRegistryEntry.self) { entry in
          if let plugin = installedPlugins.first(where: { $0.id == entry.id }) {
            PluginDetailScreen(plugin: plugin)
          } else {
            PluginDetailScreen(entry: entry, onInstall: { onInstall(entry) })
          }
        }
    }
    .task(id: environment.pluginAccess.revision) { await load() }
  }

  @ViewBuilder
  private var content: some View {
    if let entries {
      List {
        if entries.isEmpty {
          ContentUnavailableView {
            Label("No Plugins Published", systemImage: "puzzlepiece")
          } description: {
            Text(
              """
              Plugins appear here when their authors publish them — a public \
              GitHub repo tagged codevisor-plugin. Yours could be first.
              """
            )
          }
        } else if filtered.isEmpty {
          ContentUnavailableView {
            Label("No Results for “\(query)”", systemImage: "magnifyingglass")
          }
        } else {
          ForEach(filtered) { entry in
            entryRow(entry)
          }
        }
      }
      .searchable(text: $query, prompt: "Search plugins")
    } else if let errorMessage {
      ContentUnavailableView {
        Label("Registry Unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("Retry") { Task { await load() } }
      }
    } else {
      ProgressView()
        .accessibilityLabel("Loading the plugin registry")
    }
  }

  private func entryRow(_ entry: ServerPluginRegistryEntry) -> some View {
    NavigationLink(value: entry) {
      HStack(spacing: 12) {
        PluginRegistryAvatarView(urlString: entry.ownerAvatarUrl, size: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name)
          if let description = entry.description, !description.isEmpty {
            Text(description)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        PluginSafetyButton(pluginId: entry.id, name: entry.name)
        if PluginRegistryBrowsing.isInstalled(entry, installedIds: installedIds) {
          Text("Installed")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          Button("Install") { onInstall(entry) }
            .font(.callout.weight(.medium))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(entry.name))
  }

  private func load() async {
    errorMessage = nil
    do {
      let registry = try await fetchRegistry()
      let (policy, preferences) = try await environment.pluginAccess.snapshot()
      entries = registry.entries.filter {
        policy.restriction(pluginId: $0.id, ageRating: $0.ageRating, blockedPublishers: preferences.blockedPublishers)
          == nil
      }
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
