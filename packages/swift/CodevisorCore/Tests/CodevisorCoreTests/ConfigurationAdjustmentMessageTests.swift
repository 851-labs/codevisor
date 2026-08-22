import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

/// Covers the "<model> is no longer available" notice. It had no coverage while
/// it was reachable from a throwaway harness inspection, which is exactly how it
/// came to fire on nearly every chat open while the picker still listed the
/// saved model.
@MainActor
@Suite("Configuration adjustment message")
struct ConfigurationAdjustmentMessageTests {
    private func modelOption(
        current: String,
        available: [(String, String)]
    ) -> SessionConfigOption {
        SessionConfigOption(
            id: "model",
            name: "Model",
            category: SessionConfigOption.Category.model,
            currentValue: current,
            options: available.map { SessionConfigSelectOption(value: $0.0, name: $0.1) }
        )
    }

    @Test("Restored selection reports no adjustment")
    func restoredSelectionIsSilent() {
        let message = SessionController.configurationAdjustmentMessage(
            saved: ["model": "fable"],
            validated: [modelOption(current: "fable", available: [("fable", "Fable 5"), ("opus", "Opus")])]
        )
        #expect(message == nil)
    }

    @Test("Withdrawn model names the replacement")
    func withdrawnModelIsReported() {
        let message = SessionController.configurationAdjustmentMessage(
            saved: ["model": "fable"],
            validated: [modelOption(current: "opus", available: [("opus", "Opus (1M context)")])]
        )
        // The withdrawn value is no longer listed, so its raw id is all there
        // is to show; the replacement resolves to its display name.
        #expect(message == "fable is no longer available. Using Opus (1M context).")
    }

    @Test("A still-listed previous value reports a restore failure, not removal")
    func selectablePreviousValueReportsRestoreFailure() {
        let message = SessionController.configurationAdjustmentMessage(
            saved: ["model": "fable"],
            validated: [modelOption(current: "opus", available: [("fable", "Fable 5"), ("opus", "Opus")])]
        )
        #expect(message == "Fable 5 couldn’t be restored. Using Opus.")
    }

    @Test("An option the snapshot omits entirely is not reported as lost")
    func absentOptionIsNotLoss() {
        // `speed` exists only for some models, so its absence is routine and
        // must not be read as the saved selection having been dropped.
        let message = SessionController.configurationAdjustmentMessage(
            saved: ["model": "opus", "speed": "fast"],
            validated: [modelOption(current: "opus", available: [("opus", "Opus")])]
        )
        #expect(message == nil)
    }

    @Test("A selectable non-model change reports a restore failure")
    func nonModelRestoreFailureIsGeneric() {
        let effort = SessionConfigOption(
            id: "effort",
            name: "Effort",
            category: SessionConfigOption.Category.thoughtLevel,
            currentValue: "high",
            options: [
                SessionConfigSelectOption(value: "high", name: "High"),
                SessionConfigSelectOption(value: "max", name: "Max"),
            ]
        )
        let message = SessionController.configurationAdjustmentMessage(
            saved: ["effort": "max"],
            validated: [effort]
        )
        #expect(
            message
                == "Some saved settings couldn’t be restored. Current harness values are being used."
        )
    }

    @Test("A withdrawn non-model value keeps the unavailable notice")
    func nonModelRemovalIsGeneric() {
        let effort = SessionConfigOption(
            id: "effort",
            name: "Effort",
            category: SessionConfigOption.Category.thoughtLevel,
            currentValue: "high",
            options: [SessionConfigSelectOption(value: "high", name: "High")]
        )
        let message = SessionController.configurationAdjustmentMessage(
            saved: ["effort": "max"],
            validated: [effort]
        )
        #expect(
            message
                == "Some saved settings are no longer available. Current harness defaults are being used."
        )
    }

    @Test("No saved selections reports nothing")
    func emptySavedIsSilent() {
        #expect(SessionController.configurationAdjustmentMessage(saved: nil, validated: []) == nil)
        #expect(SessionController.configurationAdjustmentMessage(saved: [:], validated: []) == nil)
    }
}
