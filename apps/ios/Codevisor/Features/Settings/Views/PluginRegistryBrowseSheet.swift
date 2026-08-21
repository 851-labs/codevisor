import CodevisorCore
import CodevisorUI
import SwiftUI

/// Browse the public plugin registry: a searchable list of GitHub-indexed
/// plugins served through this machine (`GET /v1/plugins/registry`). The list
/// stays scannable — artwork, name, one-line description, Install — and
/// tapping a row pushes the full story (panes, tools, repo facts). Purely
/// discovery — Install hands the entry's repo to the existing install sheet,
/// so consent (verbatim commands + declared tools) is unchanged. The iOS
/// twin of macOS's PluginRegistryBrowseSheet.
struct PluginRegistryBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
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
                    PluginRegistryDetailScreen(
                        entry: entry,
                        isInstalled: PluginRegistryBrowsing.isInstalled(
                            entry,
                            installedIds: installedIds
                        ),
                        onInstall: { onInstall(entry) }
                    )
                }
        }
        .task { await load() }
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
                    // Not ContentUnavailableView.search: its stock "Check the
                    // spelling…" advice is noise here.
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
            // Registry unreachable and nothing cached server-side: browsing
            // is unavailable, but manual installs still work.
            ContentUnavailableView {
                Label("Registry Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            }
        } else {
            ProgressView()
                .accessibilityLabel("Loading the plugin registry")
        }
    }

    /// One glanceable line per plugin: artwork, name, what it does, Install.
    /// Everything else (version, repo, stars, capabilities) lives on the
    /// detail screen behind the row.
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
        do {
            entries = try await fetchRegistry().entries
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}

/// Everything the list row leaves out, shown before any commitment: what the
/// plugin adds (panes, agent tools) and the GitHub facts that anchor it to a
/// real owner (repo, stars, last push). Install goes through the same
/// discover→consent flow as everywhere else. The iOS twin of macOS's
/// PluginRegistryDetailView.
private struct PluginRegistryDetailScreen: View {
    let entry: ServerPluginRegistryEntry
    let isInstalled: Bool
    let onInstall: () -> Void

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    PluginRegistryAvatarView(urlString: entry.ownerAvatarUrl, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.headline)
                        Text("by \(PluginRegistryBrowsing.owner(of: entry))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isInstalled {
                        Text("Installed")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Install") { onInstall() }
                            .font(.callout.weight(.medium))
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
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
                                .font(.callout.monospaced())
                            Text(tool.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Information") {
                // Pane titles as plain text: pane artwork is served by the
                // plugin's own server, which isn't running pre-install.
                if !entry.panes.isEmpty {
                    LabeledContent(
                        "Panes",
                        value: entry.panes.map(\.title).joined(separator: ", ")
                    )
                }
                LabeledContent("Version", value: entry.version)
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
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
