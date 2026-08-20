import Testing
@testable import TranscriptKit

@Suite("Transcript attention presentation")
struct TranscriptAttentionPresentationStateTests {
    @Test("Acknowledgement requires the foreground chat in the active key window")
    func acknowledgementEligibility() {
        let eligible = TranscriptAttentionPresentationState(
            isReadEligible: true,
            isApplicationActive: true,
            isWindowKey: true,
            isWindowVisible: true,
            isWindowOnScreen: true
        )
        #expect(eligible.allowsAcknowledgement)

        #expect(!state(readEligible: false).allowsAcknowledgement)
        #expect(!state(applicationActive: false).allowsAcknowledgement)
        #expect(!state(windowKey: false).allowsAcknowledgement)
        #expect(!state(windowVisible: false).allowsAcknowledgement)
        #expect(!state(windowOnScreen: false).allowsAcknowledgement)
    }

    private func state(
        readEligible: Bool = true,
        applicationActive: Bool = true,
        windowKey: Bool = true,
        windowVisible: Bool = true,
        windowOnScreen: Bool = true
    ) -> TranscriptAttentionPresentationState {
        TranscriptAttentionPresentationState(
            isReadEligible: readEligible,
            isApplicationActive: applicationActive,
            isWindowKey: windowKey,
            isWindowVisible: windowVisible,
            isWindowOnScreen: windowOnScreen
        )
    }
}
