import Testing
@testable import CodevisorCore

struct TranscriptInitialPresentationGateTests {
    @Test func hydrationCannotRevealAnEmptyPlaceholder() {
        var gate = TranscriptInitialPresentationGate()

        let revealed = gate.resolve(
            isHydrating: true,
            requiredKeys: [],
            resolvedKeys: [],
        )
        #expect(!revealed)
        #expect(!gate.isReady)
    }

    @Test func uncachedWindowWaitsForEveryRequiredRow() {
        var gate = TranscriptInitialPresentationGate()

        let partialReveal = gate.resolve(
            isHydrating: false,
            requiredKeys: ["a", "b", "c"],
            resolvedKeys: ["a", "c"],
        )
        #expect(!partialReveal)
        #expect(!gate.isReady)

        let completeReveal = gate.resolve(
            isHydrating: false,
            requiredKeys: ["a", "b", "c"],
            resolvedKeys: ["a", "b", "c"],
        )
        #expect(completeReveal)
        #expect(gate.isReady)
    }

    @Test func changingInitialWindowMustAlsoResolveNewRows() {
        var gate = TranscriptInitialPresentationGate()

        let firstWindowReveal = gate.resolve(
            isHydrating: false,
            requiredKeys: ["a", "b"],
            resolvedKeys: ["a"],
        )
        #expect(!firstWindowReveal)
        let changedWindowReveal = gate.resolve(
            isHydrating: false,
            requiredKeys: ["b", "c"],
            resolvedKeys: ["a", "b"],
        )
        #expect(!changedWindowReveal)
        let finalReveal = gate.resolve(
            isHydrating: false,
            requiredKeys: ["b", "c"],
            resolvedKeys: ["a", "b", "c"],
        )
        #expect(finalReveal)
    }

    @Test func cachedWindowRevealsImmediatelyAndNeverHidesAgain() {
        var gate = TranscriptInitialPresentationGate()

        let cachedReveal = gate.resolve(
            isHydrating: false,
            requiredKeys: ["cached"],
            resolvedKeys: ["cached"],
        )
        #expect(cachedReveal)
        let secondReveal = gate.resolve(
            isHydrating: true,
            requiredKeys: ["different"],
            resolvedKeys: [],
        )
        #expect(!secondReveal)
        #expect(gate.isReady)
    }
}
