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
}
