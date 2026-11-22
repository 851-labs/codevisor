import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("PrivacySettingsSync")
struct PrivacySettingsSyncTests {
  private let earlyRemoteWrite = 1

  private func receive(_ environment: AppEnvironment, _ choice: PrivacyChoice, _ enabled: Bool, wallMs: Int) {
    environment.configSync.applyRemoteChange(
      namespace: PrivacySettingsSync.namespace,
      entries: [
        ServerSyncEntry(
          key: choice.rawValue,
          value: .bool(enabled),
          timestamp: ServerSyncTimestamp(wallMs: wallMs, counter: 0, deviceId: "other-device")
        )
      ]
    )
  }

  private func synced(_ environment: AppEnvironment, _ choice: PrivacyChoice) -> JSONValue? {
    environment.configSync.value(namespace: PrivacySettingsSync.namespace, key: choice.rawValue)
  }

  @Test("An opt-out from before syncing outranks an earlier opt-in from another device")
  func optOutFromBeforeSyncWins() {
    let environment = AppEnvironment.preview()
    environment.syncPrivacySettings()

    receive(environment, .shareCrashReports, true, wallMs: earlyRemoteWrite)

    #expect(!environment.settings.shareCrashReports)
    #expect(synced(environment, .shareCrashReports) == .bool(false))
  }

  @Test("An opt-in from before syncing yields to any real choice made on another device")
  func optInFromBeforeSyncYields() {
    let environment = AppEnvironment.preview()
    environment.settings.setShareAnalytics(true)
    environment.syncPrivacySettings()
    #expect(synced(environment, .shareAnalytics) == .bool(true))

    receive(environment, .shareAnalytics, false, wallMs: earlyRemoteWrite)

    #expect(!environment.settings.shareAnalytics)
  }

  @Test("Changing a choice here publishes it for every machine")
  func localChoicePublishes() {
    let environment = AppEnvironment.preview()
    environment.syncPrivacySettings()

    environment.setShareCrashReports(true)

    #expect(environment.settings.shareCrashReports)
    #expect(synced(environment, .shareCrashReports) == .bool(true))
  }
}
