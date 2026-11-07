import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("FeatureFlagSync")
struct FeatureFlagSyncTests {
  private func receive(_ environment: AppEnvironment, _ flag: FeatureFlag, _ enabled: Bool, wallMs: Int) {
    environment.configSync.applyRemoteChange(
      namespace: FeatureFlagSync.namespace,
      entries: [
        ServerSyncEntry(
          key: flag.rawValue,
          value: .bool(enabled),
          timestamp: ServerSyncTimestamp(wallMs: wallMs, counter: 0, deviceId: "other-device")
        )
      ]
    )
  }

  private func isOn(_ flag: FeatureFlag, in preferences: ClientPreferences) -> Bool {
    preferences.value(forKey: flag.preferenceKey, default: false)
  }

  @Test("A flag flipped on any device applies here, and a flip here publishes for the others")
  func flagsFollowTheSyncedValue() {
    let environment = AppEnvironment.preview()
    let preferences = ClientPreferences()
    environment.syncFeatureFlags(preferences: preferences)
    #expect(!isOn(.bots, in: preferences))

    receive(environment, .bots, true, wallMs: 20_000_000_000_000)
    #expect(isOn(.bots, in: preferences))

    environment.setFeatureFlag(.bots, enabled: false)
    #expect(!isOn(.bots, in: preferences))
    #expect(environment.configSync.value(namespace: FeatureFlagSync.namespace, key: "bots") == .bool(false))
  }

  @Test("Flags turned on before syncing carry over, but yield to any real change from another device")
  func flagsFromBeforeSyncCarryOver() {
    let environment = AppEnvironment.preview()
    let preferences = ClientPreferences()
    preferences.set(true, forKey: FeatureFlag.bots.preferenceKey)
    preferences.set(true, forKey: FeatureFlag.developerMode.preferenceKey)
    environment.syncFeatureFlags(preferences: preferences)
    #expect(environment.configSync.value(namespace: FeatureFlagSync.namespace, key: "bots") == .bool(true))

    receive(environment, .developerMode, false, wallMs: 1)
    #expect(isOn(.bots, in: preferences))
    #expect(!isOn(.developerMode, in: preferences))
  }
}
