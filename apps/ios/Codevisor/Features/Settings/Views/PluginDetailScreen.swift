import CodevisorCore
import CodevisorUI
import SwiftUI

/// The same destination for catalog entries, installed rows, and plugin links.
struct PluginDetailScreen: View {
  @Environment(AppEnvironment.self) private var environment
  private enum Source {
    case registry(ServerPluginRegistryEntry, onInstall: () -> Void)
    case installed(ServerPluginSummary)
  }
  private let source: Source

  init(entry: ServerPluginRegistryEntry, onInstall: @escaping () -> Void) {
    source = .registry(entry, onInstall: onInstall)
  }

  init(plugin: ServerPluginSummary) { source = .installed(plugin) }

  private var plugin: ServerPluginSummary? {
    if case .installed(let plugin) = source { return plugin }
    return nil
  }

  private var entry: ServerPluginRegistryEntry? {
    if case .registry(let entry, _) = source { return entry }
    return nil
  }

  private var id: String { plugin?.id ?? entry!.id }
  private var name: String { plugin?.name ?? entry!.name }
  private var version: String { plugin?.version ?? entry!.version }
  private var description: String? { plugin?.description ?? entry?.description }
  private var panes: [ServerPluginPaneDescriptor] { plugin?.panes ?? entry!.panes }
  private var tools: [ServerPluginToolDescriptor] { plugin?.tools ?? entry?.tools ?? [] }
  private var repo: String? { plugin?.sourceRepo ?? entry?.repo }
  private var publisher: String {
    repo?.split(separator: "/").first.map(String.init) ?? String(id.split(separator: ".").first ?? "")
  }

  var body: some View {
    List {
      Section {
        HStack(spacing: 14) {
          PluginRegistryAvatarView(urlString: entry?.ownerAvatarUrl, size: 52)
          VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.headline)
            Text("by \(publisher)").font(.callout).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          PluginSafetyButton(pluginId: id, name: name)
          if plugin != nil {
            Text("Installed").font(.callout).foregroundStyle(.secondary)
          }
        }
        if let description, !description.isEmpty {
          Text(description).foregroundStyle(.secondary)
        }
      }
      if !tools.isEmpty {
        Section("Agent Tools") {
          ForEach(tools) { tool in
            VStack(alignment: .leading, spacing: 2) {
              Text(tool.name).font(.callout.monospaced())
              Text(tool.description).font(.footnote).foregroundStyle(.secondary)
            }
          }
        }
      }
      Section("Information") {
        if !panes.isEmpty {
          LabeledContent("Panes", value: panes.map(\.title).joined(separator: ", "))
        }
        LabeledContent("Version", value: version)
        PluginAgeRatingRow(pluginId: id, declared: plugin?.ageRating ?? entry?.ageRating)
        if let entry {
          LabeledContent("Stars", value: PluginRegistryBrowsing.starsText(for: entry))
          if let updated = PluginRegistryBrowsing.updatedText(for: entry) {
            LabeledContent("Updated", value: updated)
          }
        }
        if let repo, let url = URL(string: "https://github.com/\(repo)") {
          Link(destination: url) {
            LabeledContent("GitHub") {
              HStack(spacing: 4) {
                Text(repo)
                Image(systemName: "arrow.up.right").font(.caption2)
              }
            }
          }
          .foregroundStyle(.primary)
        }
      }
    }
    .navigationTitle(name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if case .registry(_, let install) = source {
        ToolbarItem(placement: .confirmationAction) {
          Button("Install", action: install)
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
      }
    }
    .task(id: environment.pluginAccess.revision) {
      _ = try? await environment.pluginAccess.refreshPolicy()
    }
  }
}
