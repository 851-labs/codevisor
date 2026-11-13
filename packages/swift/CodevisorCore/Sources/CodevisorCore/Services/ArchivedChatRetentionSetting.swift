import ACPKit
import Foundation

@MainActor
public struct ArchivedChatRetentionSetting {
  static let namespace = "settings"
  static let key = "archivedChatRetention"

  private let configSync: ConfigSync

  public init(configSync: ConfigSync) {
    self.configSync = configSync
  }

  public var current: ArchivedChatRetention {
    _ = configSync.revisionsByNamespace[Self.namespace]
    guard case let .string(raw)? = configSync.value(namespace: Self.namespace, key: Self.key) else {
      return .standard
    }
    return ArchivedChatRetention(rawValue: raw) ?? .standard
  }

  public func choose(_ retention: ArchivedChatRetention) {
    guard retention != current else { return }
    configSync.set(namespace: Self.namespace, key: Self.key, value: .string(retention.rawValue))
  }
}
