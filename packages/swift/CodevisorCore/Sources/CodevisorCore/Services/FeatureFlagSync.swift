import ACPKit
import Foundation

@MainActor
final class FeatureFlagSync {
  static let namespace = "feature-flags"

  private let preferences: ClientPreferences
  private let configSync: ConfigSync

  init(preferences: ClientPreferences, configSync: ConfigSync) {
    self.preferences = preferences
    self.configSync = configSync
  }

  func start() {
    publishFlagsFromBeforeSync()
    adoptSyncedValues()
  }

  func adoptSyncedValues() {
    for flag in FeatureFlag.allCases {
      let enabled = configSync.value(namespace: Self.namespace, key: flag.rawValue) == .bool(true)
      guard enabled != preferences.value(forKey: flag.preferenceKey, default: false) else { continue }
      preferences.store(try? JSONEncoder().encode(enabled), forKey: flag.preferenceKey)
    }
  }

  private func publishFlagsFromBeforeSync() {
    let synced = Set(configSync.entries(namespace: Self.namespace).map(\.key))
    let olderThanAnyWrite = ServerSyncTimestamp(wallMs: 0, counter: 0, deviceId: configSync.deviceId)
    let entries = FeatureFlag.allCases
      .filter { !synced.contains($0.rawValue) && preferences.value(forKey: $0.preferenceKey, default: false) }
      .map { ServerSyncEntry(key: $0.rawValue, value: .bool(true), timestamp: olderThanAnyWrite) }
    guard !entries.isEmpty else { return }
    configSync.applyRemoteChange(namespace: Self.namespace, entries: entries)
  }
}
