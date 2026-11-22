import ACPKit
import Foundation

public enum PrivacyChoice: String, CaseIterable, Sendable {
  case shareAnalytics
  case shareCrashReports
}

@MainActor
final class PrivacySettingsSync {
  static let namespace = "settings"

  private let settings: AppSettingsModel
  private let configSync: ConfigSync

  init(settings: AppSettingsModel, configSync: ConfigSync) {
    self.settings = settings
    self.configSync = configSync
  }

  func start() {
    let synced = Set(configSync.entries(namespace: Self.namespace).map(\.key))
    for choice in PrivacyChoice.allCases where !synced.contains(choice.rawValue) {
      publishFromBeforeSync(choice, enabled: localValue(choice))
    }
  }

  func publish(_ choice: PrivacyChoice, enabled: Bool) {
    configSync.set(namespace: Self.namespace, key: choice.rawValue, value: .bool(enabled))
  }

  func syncedValue(_ choice: PrivacyChoice) -> Bool? {
    guard case let .bool(enabled)? = configSync.value(namespace: Self.namespace, key: choice.rawValue)
    else { return nil }
    return enabled
  }

  private func publishFromBeforeSync(_ choice: PrivacyChoice, enabled: Bool) {
    guard enabled else {
      publish(choice, enabled: false)
      return
    }
    let olderThanAnyWrite = ServerSyncTimestamp(wallMs: 0, counter: 0, deviceId: configSync.deviceId)
    let entry = ServerSyncEntry(key: choice.rawValue, value: .bool(true), timestamp: olderThanAnyWrite)
    configSync.applyRemoteChange(namespace: Self.namespace, entries: [entry])
  }

  private func localValue(_ choice: PrivacyChoice) -> Bool {
    switch choice {
    case .shareAnalytics: settings.shareAnalytics
    case .shareCrashReports: settings.shareCrashReports
    }
  }
}
