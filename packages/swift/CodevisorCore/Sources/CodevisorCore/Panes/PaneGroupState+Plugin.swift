import Foundation

/// Wrapper making pane-array decoding element-lenient: an element that fails
/// to decode (a pane kind from a NEWER build) yields nil instead of throwing,
/// so one unknown pane never nukes a whole persisted group.
struct LenientPaneDescriptorState: Decodable {
    let pane: PaneDescriptorState?

    init(from decoder: Decoder) throws {
        pane = try? PaneDescriptorState(from: decoder)
    }
}

/// The plugin fields the server's pane record carries as opaque metadata:
/// enough for any client to rebuild the descriptor (and its tab icon)
/// without consulting the plugin manifest.
struct PluginPaneMetadata: Codable, Equatable {
    var pluginId: String
    var paneType: String
    var icon: String?
}

extension PaneDescriptorState {
    /// The canonical metadata JSON for a plugin pane. Deterministic
    /// (sorted keys) so a locally-created pane compares equal to its own
    /// server echo in the optimistic sync barrier.
    public static func pluginMetadataJSON(
        pluginId: String,
        paneType: String,
        icon: String? = nil
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = PluginPaneMetadata(pluginId: pluginId, paneType: paneType, icon: icon)
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The manifest icon carried in the plugin metadata, if any. Tab strips
    /// fall back to a generic puzzle-piece symbol when absent.
    public var pluginIcon: String? {
        guard let pluginMetadata, let data = pluginMetadata.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(PluginPaneMetadata.self, from: data))?.icon
    }
}

extension PaneGroupState {
    /// Builds a plugin pane descriptor for `convertNewTabPane`. Nil when the
    /// plugin identity is incomplete (a plugin pane without its plugin is
    /// unrenderable).
    static func pluginPane(
        id: UUID,
        name: String?,
        pluginId: String?,
        pluginPaneType: String?,
        pluginIcon: String?
    ) -> PaneDescriptorState? {
        guard let pluginId, !pluginId.isEmpty, let pluginPaneType, !pluginPaneType.isEmpty
        else { return nil }
        return PaneDescriptorState(
            id: id,
            kind: .plugin,
            name: name ?? "Plugin",
            terminalKey: id.uuidString,
            pluginId: pluginId,
            pluginPaneType: pluginPaneType,
            pluginMetadata: PaneDescriptorState.pluginMetadataJSON(
                pluginId: pluginId, paneType: pluginPaneType, icon: pluginIcon
            )
        )
    }
}
