import Foundation
import Testing
@testable import CodevisorCore

@Suite("App settings onboarding step")
struct AppSettingsOnboardingStepTests {
  @Test("Resumes onboarding on the step a mid-flow restart left off")
  @MainActor
  func persistsOnboardingStep() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    #expect(model.onboardingStep == nil)

    model.setOnboardingStep(2)
    #expect(AppSettingsModel(store: store).onboardingStep == 2)

    model.completeOnboarding(importExternalSessions: false)
    let reloaded = AppSettingsModel(store: store)
    #expect(reloaded.hasCompletedOnboarding)
    #expect(reloaded.onboardingStep == nil)
  }
}
