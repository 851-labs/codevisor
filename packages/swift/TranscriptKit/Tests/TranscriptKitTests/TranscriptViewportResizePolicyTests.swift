import Testing
@testable import TranscriptKit

@Suite("Transcript viewport resize policy")
struct TranscriptViewportResizePolicyTests {
    @Test("A bottom transcript remains pinned through viewport changes")
    func bottomRemainsPinned() {
        #expect(
            TranscriptViewportResizeAdjustment.resolve(
                previousDistanceFromBottom: 0,
                atBottomThreshold: 2,
                isUserInteracting: false
            ) == .pinToBottom
        )
        #expect(
            TranscriptViewportResizeAdjustment.resolve(
                previousDistanceFromBottom: 2,
                atBottomThreshold: 2,
                isUserInteracting: false
            ) == .pinToBottom
        )
    }

    @Test("A static transcript keeps the content under the user stationary")
    func staticTranscriptKeepsItsOffset() {
        #expect(
            TranscriptViewportResizeAdjustment.resolve(
                previousDistanceFromBottom: 2.5,
                atBottomThreshold: 2,
                isUserInteracting: false
            ) == .keepContentOffset
        )
    }

    @Test("Direct manipulation always wins over automatic anchoring")
    func userInteractionKeepsItsOffset() {
        #expect(
            TranscriptViewportResizeAdjustment.resolve(
                previousDistanceFromBottom: 0,
                atBottomThreshold: 2,
                isUserInteracting: true
            ) == .keepContentOffset
        )
    }
}
