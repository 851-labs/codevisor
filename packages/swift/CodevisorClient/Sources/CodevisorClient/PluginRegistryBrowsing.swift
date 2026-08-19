import Foundation

/// Pure presentation logic for the Settings ▸ Plugins ▸ Browse experience,
/// shared by the macOS and iOS registry sheets so both platforms filter and
/// describe entries identically.
public enum PluginRegistryBrowsing {
    /// Case-insensitive substring match over the fields the browse UI renders
    /// (id, name, description, repo) — the client-side twin of
    /// `filterPluginRegistryIndex` in packages/plugins, so live typing and
    /// server-side `?q=` agree on what matches.
    public static func filter(
        _ entries: [ServerPluginRegistryEntry],
        query: String
    ) -> [ServerPluginRegistryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            [entry.id, entry.name, entry.description ?? "", entry.repo]
                .contains { $0.lowercased().contains(needle) }
        }
    }

    /// "2 panes · 1 agent tool" — what installing the entry adds. Empty when
    /// the manifest declares neither (the registry accepts tool-only and
    /// pane-only plugins alike).
    public static func capabilitySummary(for entry: ServerPluginRegistryEntry) -> String {
        var parts: [String] = []
        if !entry.panes.isEmpty {
            parts.append("\(entry.panes.count) pane\(entry.panes.count == 1 ? "" : "s")")
        }
        if let tools = entry.tools, !tools.isEmpty {
            parts.append("\(tools.count) agent tool\(tools.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    /// An entry is "already installed" when a plugin with its id is on the
    /// machine — same identity rule the install pipeline uses, so the marker
    /// and `alreadyInstalled` on the consent sheet always agree.
    public static func isInstalled(
        _ entry: ServerPluginRegistryEntry,
        installedIds: Set<String>
    ) -> Bool {
        installedIds.contains(entry.id)
    }
}
