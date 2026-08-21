import CodevisorCore
import SwiftUI
import CodevisorUI

/// Browse the public plugin registry: a searchable list of GitHub-indexed
/// plugins served through this machine (`GET /v1/plugins/registry`). Purely
/// discovery — Install hands the entry's repo to the existing install sheet,
/// so consent (verbatim commands + declared tools) is unchanged.
struct PluginRegistryBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let fetchRegistry: () async throws -> ServerPluginRegistryIndex
    let installedIds: Set<String>
    let onInstall: (ServerPluginRegistryEntry) -> Void

    @State private var entries: [ServerPluginRegistryEntry]?
    @State private var errorMessage: String?
    @State private var query = ""

    private var filtered: [ServerPluginRegistryEntry] {
        PluginRegistryBrowsing.filter(entries ?? [], query: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 520, height: 480)
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
                        prompt: Text(verbatim: "Search plugins by name, description, or repo")
                    )
                }
                .listRowBackground(themedFormRowBackground)
                Section {
                    if entries.isEmpty {
                        Text("No plugins have been published yet.")
                            .foregroundStyle(.secondary)
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
                .listRowBackground(themedFormRowBackground)
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        } else if let errorMessage {
            // Registry unreachable and nothing cached server-side: browsing
            // is unavailable, but manual installs still work.
            ContentUnavailableView {
                Label("Registry Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.regular)
                .tint(theme.isSystem ? nil : theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading the plugin registry")
        }
    }

    private func entryRow(_ entry: ServerPluginRegistryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).foregroundStyle(.primary)
                    Text(entry.version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if PluginRegistryBrowsing.isInstalled(entry, installedIds: installedIds) {
                        installedChip
                    }
                }
                Text(subtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let description = entry.description, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Install…") { onInstall(entry) }
                .settingsActionTint(theme)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(subtitle(entry))")
    }

    /// One line, densest first: the real repo owner, what installing adds,
    /// and the GitHub stars that anchor the entry's reputation.
    private func subtitle(_ entry: ServerPluginRegistryEntry) -> String {
        let capabilities = PluginRegistryBrowsing.capabilitySummary(for: entry)
        let stars = "\(entry.stars) star\(entry.stars == 1 ? "" : "s")"
        return ([entry.repo, capabilities, stars].filter { !$0.isEmpty }).joined(separator: " · ")
    }

    private var installedChip: some View {
        Text("Installed")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.isSystem ? AnyShapeStyle(.quaternary) : AnyShapeStyle(theme.cardQuietBackground))
            )
            .foregroundStyle(theme.isSystem ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusOK))
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
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
