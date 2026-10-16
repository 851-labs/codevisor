import CodevisorCore
import SwiftUI
import CodevisorUI

struct PluginRegistryBrowseSheet: View {
  @Environment(\.dismiss) private var dismiss
  let fetchRegistry: () async throws -> ServerPluginRegistryIndex
  let installedIds: Set<String>
  let onInstall: (ServerPluginRegistryEntry) -> Void

  @State private var entries: [ServerPluginRegistryEntry]?
  @State private var errorMessage: String?
  @State private var query = ""
  @State private var selectedEntry: ServerPluginRegistryEntry?

  private var filtered: [ServerPluginRegistryEntry] {
    PluginRegistryBrowsing.filter(entries ?? [], query: query)
  }

  var body: some View {
    VStack(spacing: 0) {
      NavigationStack {
        content
          .navigationDestination(item: $selectedEntry) { entry in
            PluginRegistryDetailView(
              entry: entry,
              isInstalled: PluginRegistryBrowsing.isInstalled(
                entry,
                installedIds: installedIds
              ),
              onInstall: { onInstall(entry) }
            )
          }
      }
      Divider()
      HStack {
        Spacer()
        Button("Close") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding()
      .themedSurface(.sheet)
    }
    .frame(width: 520, height: 520)
    .themedSurface(.sheet)
    .task { await load() }
  }

  @ViewBuilder
  private var content: some View {
    if let entries {
      Form {
        Section {
          TextField(
            "Search",
            text: $query,
            prompt: Text(verbatim: "Search plugins")
          )
        }
        Section {
          if entries.isEmpty {
            emptyRegistryText
          } else if filtered.isEmpty {
            Text("No plugins match “\(query)”.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(filtered) { entry in
              entryRow(entry)
            }
          }
        } header: {
          Text("Plugin Registry")
        }
      }
      .formStyle(.grouped)
    } else if let errorMessage {
      ContentUnavailableView {
        Label("Registry Unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text(errorMessage)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView()
        .controlSize(.regular)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading the plugin registry")
    }
  }

  private var emptyRegistryText: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("No plugins have been published yet.")
        .foregroundStyle(.secondary)
      Text(
        "Publish yours by tagging a public GitHub repo with the codevisor-plugin topic."
      )
      .font(.callout)
      .foregroundStyle(.tertiary)
    }
  }

  private func entryRow(_ entry: ServerPluginRegistryEntry) -> some View {
    HStack(spacing: 10) {
      PluginRegistryAvatarView(urlString: entry.ownerAvatarUrl, size: 30)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.name).foregroundStyle(.primary)
        if let description = entry.description, !description.isEmpty {
          Text(description)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      PluginSafetyButton(pluginId: entry.id, name: entry.name)
      if PluginRegistryBrowsing.isInstalled(entry, installedIds: installedIds) {
        installedChip
      } else {
        Button("Install") { onInstall(entry) }
      }
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
    .onTapGesture { selectedEntry = entry }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(entry.name))
    .accessibilityHint(Text("Shows details for \(entry.name)"))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default) { selectedEntry = entry }
  }

  private var installedChip: some View {
    Text("Installed")
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 5)
      .padding(.vertical, 1)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(.quaternary)
      )
      .foregroundStyle(.secondary)
  }

  private func load() async {
    do {
      entries = try await fetchRegistry().entries
      errorMessage = nil
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}

private struct PluginRegistryDetailView: View {
  let entry: ServerPluginRegistryEntry
  let isInstalled: Bool
  let onInstall: () -> Void

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          PluginRegistryAvatarView(urlString: entry.ownerAvatarUrl, size: 44)
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.name)
              .font(.headline)
            Text("by \(PluginRegistryBrowsing.owner(of: entry))")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          PluginSafetyButton(pluginId: entry.id, name: entry.name)
          if isInstalled {
            Text("Installed")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            Button("Install…") { onInstall() }
          }
        }
        if let description = entry.description, !description.isEmpty {
          Text(description)
            .foregroundStyle(.secondary)
        }
      }
      if let tools = entry.tools, !tools.isEmpty {
        Section("Agent Tools") {
          ForEach(tools) { tool in
            VStack(alignment: .leading, spacing: 2) {
              Text(tool.name)
                .font(.body.monospaced())
              Text(tool.description)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      Section("Information") {
        if !entry.panes.isEmpty {
          LabeledContent(
            "Panes",
            value: entry.panes.map(\.title).joined(separator: ", ")
          )
        }
        LabeledContent("Version", value: entry.version)
        if let age = entry.ageRating { LabeledContent("Age Rating", value: "\(age)+") }
        LabeledContent("Stars", value: PluginRegistryBrowsing.starsText(for: entry))
        if let updated = PluginRegistryBrowsing.updatedText(for: entry) {
          LabeledContent("Updated", value: updated)
        }
        if let url = URL(string: "https://github.com/\(entry.repo)") {
          Link(destination: url) {
            LabeledContent("GitHub") {
              HStack(spacing: 4) {
                Text(entry.repo)
                Image(systemName: "arrow.up.right")
                  .font(.caption2)
              }
            }
          }
          .foregroundStyle(.primary)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(entry.name)
  }

}
