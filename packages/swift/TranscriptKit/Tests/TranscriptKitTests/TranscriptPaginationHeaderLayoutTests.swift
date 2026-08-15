import Testing
@testable import TranscriptKit

struct TranscriptPaginationHeaderLayoutTests {
    @Test func remainsUnreservedWhenPaginationIsUnavailable() {
        var layout = TranscriptPaginationHeaderLayout()

        let changed = layout.reserveIfNeeded(hasOlderHistory: false, isPresented: false)
        #expect(!changed)
        #expect(layout.height == 0)
        #expect(layout.rowOrigin(topPadding: 12, rowOffset: 50) == 62)
    }

    @Test func reservesBeforeLoadingAndDoesNotCollapseDuringTheSurfaceLifetime() {
        var layout = TranscriptPaginationHeaderLayout()

        let initiallyChanged = layout.reserveIfNeeded(
            hasOlderHistory: true,
            isPresented: false
        )
        #expect(initiallyChanged)
        #expect(layout.height == TranscriptPaginationHeaderLayout.reservedHeight)
        let changedAfterExhaustion = layout.reserveIfNeeded(
            hasOlderHistory: false,
            isPresented: false
        )
        #expect(!changedAfterExhaustion)
        #expect(layout.reservesSpace)
    }

    @Test func presentedRequestCanEstablishTheReservationAtomically() {
        var layout = TranscriptPaginationHeaderLayout()

        let changed = layout.reserveIfNeeded(hasOlderHistory: false, isPresented: true)
        #expect(changed)
        #expect(TranscriptPaginationHeaderLayout.reservedHeight == 56)
        #expect(layout.rowOrigin(topPadding: 12, rowOffset: 50) == 118)
        #expect(layout.documentHeight(topPadding: 12, rowsHeight: 500) == 568)
    }
}
