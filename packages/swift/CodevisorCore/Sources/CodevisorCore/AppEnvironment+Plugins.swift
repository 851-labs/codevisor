import Foundation

/// Plugin invalidation for machine-scoped consumers (the Plugins settings
/// pane, New Tab plugin cards) and for open plugin panes. MachineController
/// bridges `plugin.state.updated` events into `pluginStateDidChange` (views
/// observe `pluginStateRevision(for:)` and refetch the plugin list) and
/// `plugin.updated` events into `pluginDidUpdate` (open panes observe
/// `pluginUpdateRevision(forServer:pluginId:)` and reload).
extension AppEnvironment {
    /// The current plugin-state invalidation token for a machine. Views
    /// observe this value and refetch only the machine whose plugins changed.
    public func pluginStateRevision(for serverId: String) -> UInt64 {
        pluginStateRevisions[serverId, default: 0]
    }

    /// Publishes that a `plugin.state.updated` event changed a machine's
    /// plugin list or runtime state.
    public func pluginStateDidChange(onServer serverId: String) {
        pluginStateRevisions[serverId, default: 0] &+= 1
    }

    /// The current reload token for one plugin on one machine. Open plugin
    /// panes observe this value and re-run their full token→load flow when
    /// it moves (fresh pane token, fresh URL, relay origins re-resolved).
    public func pluginUpdateRevision(forServer serverId: String, pluginId: String) -> UInt64 {
        pluginUpdateRevisions[pluginUpdateKey(serverId: serverId, pluginId: pluginId), default: 0]
    }

    /// Publishes that a `plugin.updated` event changed one plugin's code or
    /// install (restart, re-import, re-link). Deliberately separate from
    /// `pluginStateDidChange`: runtime state transitions include idle
    /// shutdown, and reloading panes on those would wake the plugin in an
    /// endless idle-stop → reload loop.
    public func pluginDidUpdate(onServer serverId: String, pluginId: String) {
        pluginUpdateRevisions[pluginUpdateKey(serverId: serverId, pluginId: pluginId), default: 0] &+= 1
    }

    /// `|` cannot appear in machine ids (UUIDs/hostnames) or plugin ids
    /// (lowercase `owner.name`), so the joined key is collision-free.
    private func pluginUpdateKey(serverId: String, pluginId: String) -> String {
        "\(serverId)|\(pluginId)"
    }
}
