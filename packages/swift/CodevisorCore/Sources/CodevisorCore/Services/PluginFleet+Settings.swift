import Foundation

public extension PluginFleet {
  struct Setting: Identifiable, Equatable, Sendable {
    public var id: String
    public var enabled: Bool
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

  static func setEnabled(_ setting: Setting, enabled: Bool, in sync: ConfigSync) {
    sync.set(
      namespace: "plugins", key: setting.id,
      value: .object(["enabled": .bool(enabled), "source": .string(setting.source)]))
  }

  static func remove(_ pluginId: String, in sync: ConfigSync) {
    sync.remove(namespace: "plugins", key: pluginId)
  }
}
