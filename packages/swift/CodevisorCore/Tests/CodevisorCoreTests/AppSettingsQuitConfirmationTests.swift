import Foundation
import Testing
@testable import CodevisorCore

@Suite("App settings quit confirmation")
struct AppSettingsQuitConfirmationTests {
  @Test("Asks before quitting by default and persists opting out")
  @MainActor
  func persistsOptOut() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    #expect(model.confirmBeforeQuitting)

    // The alert's "Do not ask me again" checkbox.
    model.setConfirmBeforeQuitting(false)
    #expect(model.confirmBeforeQuitting == false)
    #expect(AppSettingsModel(store: store).confirmBeforeQuitting == false)

    // Settings can turn it back on.
    model.setConfirmBeforeQuitting(true)
    #expect(AppSettingsModel(store: store).confirmBeforeQuitting)
  }

  @Test("Never asks until onboarding has finished")
  @MainActor
  func onboardingSkipsConfirmation() {
    let model = AppSettingsModel(store: InMemoryStore())
    #expect(model.confirmBeforeQuitting)
    // System Settings' "Quit & Reopen" after a permission grant must
    // succeed mid-onboarding, where relaunching is expected.
    #expect(model.shouldConfirmBeforeQuitting == false)

    model.completeOnboarding(importExternalSessions: false)
    #expect(model.shouldConfirmBeforeQuitting)

    model.setConfirmBeforeQuitting(false)
    #expect(model.shouldConfirmBeforeQuitting == false)
  }

  @Test("Legacy settings payloads without the key keep asking")
  func legacyPayloadDefaultsOn() throws {
    let legacy = Data(#"{"hasCompletedOnboarding":true}"#.utf8)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
    #expect(decoded.confirmBeforeQuitting)
  }

  @Test("Round-trips the opt-out through JSON")
  func roundTrip() throws {
    let settings = AppSettings(confirmBeforeQuitting: false)
    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
    #expect(decoded.confirmBeforeQuitting == false)
    #expect(decoded == settings)
  }

  @Test("Asks before closing a working chat by default and persists opting out")
  @MainActor
  func persistsWorkingChatCloseOptOut() throws {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    #expect(model.confirmBeforeClosingWorkingChat)

    // The close alert's "Do not ask me again" is independent of ⌘Q's.
    model.setConfirmBeforeClosingWorkingChat(false)
    #expect(AppSettingsModel(store: store).confirmBeforeClosingWorkingChat == false)
    #expect(AppSettingsModel(store: store).confirmBeforeQuitting)

    let legacy = Data(#"{"hasCompletedOnboarding":true}"#.utf8)
    #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).confirmBeforeClosingWorkingChat)
  }

  @Test("Deleting all data restores the confirmation")
  @MainActor
  func resetRestoresDefault() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    model.setConfirmBeforeQuitting(false)
    model.reset()
    #expect(model.confirmBeforeQuitting)
  }
}
