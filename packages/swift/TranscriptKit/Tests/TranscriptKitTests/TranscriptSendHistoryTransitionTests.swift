import CoreGraphics
import Testing
@testable import TranscriptKit

struct TranscriptSendHistoryTransitionTests {
    @Test func retainedRowsUseClampedViewportGeometry() throws {
        let previous = VirtualTranscriptLayout(
            items: [
                .init(key: "assistant", estimatedHeight: 200),
                .init(key: "spacer", estimatedHeight: 100),
            ],
            measuredHeights: [:],
            spacing: 20
        )
        let current = VirtualTranscriptLayout(
            items: [
                .init(key: "assistant", estimatedHeight: 200),
                .init(key: "user", estimatedHeight: 40),
                .init(key: "active", estimatedHeight: 60),
                .init(key: "spacer", estimatedHeight: 100),
            ],
            measuredHeights: [:],
            spacing: 20
        )
        let previousIndex = try #require(previous.indexByKey["assistant"])
        let currentIndex = try #require(current.indexByKey["assistant"])

        let shortPreviousViewport = VirtualTranscriptViewport(
            contentHeight: previous.totalHeight,
            viewportHeight: 600
        )
        let shortCurrentViewport = VirtualTranscriptViewport(
            contentHeight: current.totalHeight,
            viewportHeight: 600
        )
        let shortPreviousScreenY =
            previous.topOffsets[previousIndex]
            - shortPreviousViewport.offsetY(distanceFromBottom: 0)
        let shortCurrentScreenY =
            current.topOffsets[currentIndex]
            - shortCurrentViewport.offsetY(distanceFromBottom: 0)
        #expect(
            TranscriptSendHistoryTransition.translationY(
                fromScreenY: shortPreviousScreenY,
                toScreenY: shortCurrentScreenY
            ) == 0
        )

        let longPreviousViewport = VirtualTranscriptViewport(
            contentHeight: previous.totalHeight,
            viewportHeight: 200
        )
        let longCurrentViewport = VirtualTranscriptViewport(
            contentHeight: current.totalHeight,
            viewportHeight: 200
        )
        let longPreviousScreenY =
            previous.topOffsets[previousIndex]
            - longPreviousViewport.offsetY(distanceFromBottom: 0)
        let longCurrentScreenY =
            current.topOffsets[currentIndex]
            - longCurrentViewport.offsetY(distanceFromBottom: 0)
        #expect(
            TranscriptSendHistoryTransition.translationY(
                fromScreenY: longPreviousScreenY,
                toScreenY: longCurrentScreenY
            ) == 140
        )
    }
}
