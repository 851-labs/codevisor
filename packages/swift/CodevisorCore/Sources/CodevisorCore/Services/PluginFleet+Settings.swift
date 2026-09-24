import Foundation

/// The fleet's desired plugin set: one entry per registry-sourced managed
/// plugin, keyed by plugin id and valued `{enabled, source}`. Linked dev
/// plugins and local-path installs never appear here — they are machine-bound
/// by definition, and the list marks them as such instead of pretending the
/// fleet has an opinion about them.
public extension PluginFleet {
  struct Setting: Identifiable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
    /// The repo/git origin any machine can install from.
    public var source: String

    public init(id: String, enabled: Bool, source: String) {
      self.id = id
      self.enabled = enabled
      self.source = source
    }
  }

  static func settings(_ sync: ConfigSync) -> [Setting] {
    _ = sync.revisionsByNamespace["plugins"]
    return sync.entries(namespace: "plugins").compactMap { entry in
      guard entry.deleted != true,
        case .object(let fields) = entry.value,
        case .bool(let enabled) = fields["enabled"] ?? .null,
        case .string(let source) = fields["source"] ?? .null
      else { return nil }
      return Setting(id: entry.key, enabled: enabled, source: source)
    }
  }

  /// Flips the fleet's wish for one plugin. Machines apply it on their next
  /// pass; nothing here waits on a server.
  static func setEnabled(_ setting: Setting, enabled: Bool, in sync: ConfigSync) {
    sync.set(
      namespace: "plugins", key: setting.id,
      value: .object(["enabled": .bool(enabled), "source": .string(setting.source)]))
  }

  /// Uninstalls a plugin everywhere by tombstoning its entry — the shape
  /// `reconcilePlugins` already treats as "remove this here".
  static func remove(_ pluginId: String, in sync: ConfigSync) {
    sync.remove(namespace: "plugins", key: pluginId)
  }
}
