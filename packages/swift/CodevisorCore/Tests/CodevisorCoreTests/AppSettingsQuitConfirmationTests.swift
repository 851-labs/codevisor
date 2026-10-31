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

    model.setConfirmBeforeQuitting(false)
    #expect(model.confirmBeforeQuitting == false)
    #expect(AppSettingsModel(store: store).confirmBeforeQuitting == false)

    model.setConfirmBeforeQuitting(true)
    #expect(AppSettingsModel(store: store).confirmBeforeQuitting)
  }

  @Test("Never asks until onboarding has finished")
  @MainActor
  func onboardingSkipsConfirmation() {
    let model = AppSettingsModel(store: InMemoryStore())
    #expect(model.confirmBeforeQuitting)
    #expect(model.shouldConfirmBeforeQuitting == false)

    model.completeOnboarding(importExternalSessions: false)
    #expect(model.shouldConfirmBeforeQuitting)

    model.setConfirmBeforeQuitting(false)
    #expect(model.shouldConfirmBeforeQuitting == false)
  }

  @Test("Asks before closing a working chat by default and persists opting out")
  @MainActor
  func persistsWorkingChatCloseOptOut() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    #expect(model.confirmBeforeClosingWorkingChat)

    model.setConfirmBeforeClosingWorkingChat(false)
    #expect(AppSettingsModel(store: store).confirmBeforeClosingWorkingChat == false)
    #expect(AppSettingsModel(store: store).confirmBeforeQuitting)
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
