import Foundation
import Testing
@testable import CodevisorCore

@Suite("App settings permissions review")
struct AppSettingsPermissionsTests {
  @Test("Persists the permissions-reviewed version across reloads")
  @MainActor
  func persistsReviewedVersion() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    #expect(model.permissionsReviewedVersion == nil)

    model.setPermissionsReviewedVersion("1.4.0")
    #expect(model.permissionsReviewedVersion == "1.4.0")

    let reloaded = AppSettingsModel(store: store)
    #expect(reloaded.permissionsReviewedVersion == "1.4.0")
  }

  @Test("Resumes onboarding on the step a mid-flow restart left off")
  @MainActor
  func persistsOnboardingStep() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    #expect(model.onboardingStep == nil)

    // Granting Screen Recording restarts the app from the permissions
    // step; the position has to survive the relaunch.
    model.setOnboardingStep(2)
    #expect(AppSettingsModel(store: store).onboardingStep == 2)

    // Finishing clears it so a later reset starts at the beginning.
    model.completeOnboarding(importExternalSessions: false)
    let reloaded = AppSettingsModel(store: store)
    #expect(reloaded.hasCompletedOnboarding)
    #expect(reloaded.onboardingStep == nil)
  }

  @Test("Decodes legacy settings payloads without a reviewed version")
  func decodesLegacyPayload() throws {
    let legacy = Data(#"{"hasCompletedOnboarding": true}"#.utf8)
    let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
    #expect(settings.hasCompletedOnboarding)
    #expect(settings.permissionsReviewedVersion == nil)
  }
}
