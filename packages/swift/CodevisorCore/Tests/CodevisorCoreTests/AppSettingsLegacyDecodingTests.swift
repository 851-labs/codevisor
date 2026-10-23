import Foundation
import Testing
@testable import CodevisorCore

@Suite("App settings legacy decoding")
struct AppSettingsLegacyDecodingTests {
  @Test("Legacy settings JSON decodes with defaults")
  func legacyDecode() throws {
    let legacy = Data("{\"hasCompletedOnboarding\": true}".utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
    #expect(decoded.hasCompletedOnboarding)
    #expect(decoded.shareAnalytics)
    #expect(decoded.notificationsEnabled)
    #expect(decoded.systemNotificationsEnabled)
    #expect(decoded.notificationSoundsEnabled)
    #expect(decoded.chatFinishedSoundPath == AppSettings.defaultNotificationSoundPath)
    #expect(decoded.actionRequiredSoundPath == AppSettings.defaultNotificationSoundPath)
  }

  @Test("Pre-onboarding legacy settings remain opted out")
  func preOnboardingLegacyAnalyticsDefault() throws {
    let legacy = Data("{\"hasCompletedOnboarding\": false}".utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
    #expect(decoded.shareAnalytics == false)
  }

  @Test("Settings saved with the removed theme keys still decode")
  func removedThemeKeys() throws {
    let saved = Data(
      """
      {"hasCompletedOnboarding": true, "confirmBeforeQuitting": false,
       "themeMode": "dark", "lightThemeId": "shiki:github-light", "darkThemeId": "custom:mine"}
      """.utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: saved)
    #expect(decoded.hasCompletedOnboarding)
    #expect(decoded.confirmBeforeQuitting == false)
  }

  @Test("Settings saved with the removed permissions-review keys still load and stop being written")
  @MainActor
  func removedPermissionsReviewKeys() throws {
    let saved = Data(
      """
      {"hasCompletedOnboarding": true, "confirmBeforeQuitting": false,
       "permissionsReviewedVersion": "1.4.0", "permissionsSetupSkipped": true,
       "permissionsReviewInProgress": true}
      """.utf8)
    let store = InMemoryStore(storage: ["settings": saved])

    let model = AppSettingsModel(store: store)
    #expect(model.hasCompletedOnboarding)
    #expect(model.confirmBeforeQuitting == false)

    model.setShareCrashReports(true)
    let resaved = try #require(store.loadData(forKey: "settings"))
    let keys = try #require(try JSONSerialization.jsonObject(with: resaved) as? [String: Any]).keys
    #expect(keys.contains("hasCompletedOnboarding"))
    #expect(!keys.contains("permissionsReviewedVersion"))
    #expect(!keys.contains("permissionsSetupSkipped"))
    #expect(!keys.contains("permissionsReviewInProgress"))
  }
}
