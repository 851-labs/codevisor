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
