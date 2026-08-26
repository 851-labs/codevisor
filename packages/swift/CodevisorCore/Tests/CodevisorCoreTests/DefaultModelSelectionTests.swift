import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

/// A draft composer must never render an empty model chip: with options
/// available but no usable current choice, the first option becomes the
/// pending selection — exactly what the send would use.
@MainActor
@Suite("DefaultModelSelection")
struct DefaultModelSelectionTests {
    @Test("A draft with no usable model choice pends the first option")
    func defaultsToFirstModel() throws {
        let controller = SessionController.preview()
        let harnessId = try #require(controller.selectedHarnessId)
        controller.configOptionsByHarness[harnessId] = [
            SessionConfigOption(
                id: "model",
                name: "Model",
                category: SessionConfigOption.Category.model,
                currentValue: "",
                options: [
                    SessionConfigSelectOption(value: "gpt-x", name: "GPT X"),
                    SessionConfigSelectOption(value: "gpt-y", name: "GPT Y"),
                ]
            )
        ]
        controller.ensureDefaultModelSelection()
        #expect(controller.modelOption?.currentValue == "gpt-x")

        // An existing valid (pending) choice is never overridden.
        controller.pendingConfigByHarness[harnessId] = ["model": "gpt-y"]
        controller.ensureDefaultModelSelection()
        #expect(controller.modelOption?.currentValue == "gpt-y")

        // A harness with no model options stays untouched.
        controller.configOptionsByHarness[harnessId] = []
        controller.pendingConfigByHarness[harnessId] = [:]
        controller.ensureDefaultModelSelection()
        #expect(controller.modelOption == nil)
    }
}
