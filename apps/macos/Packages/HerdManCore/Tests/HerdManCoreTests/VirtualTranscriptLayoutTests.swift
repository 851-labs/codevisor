import CoreGraphics
import Testing
@testable import HerdManCore

struct VirtualTranscriptLayoutTests {
    private let items = [
        VirtualTranscriptLayout.Item(key: "a", estimatedHeight: 100),
        VirtualTranscriptLayout.Item(key: "b", estimatedHeight: 200),
        VirtualTranscriptLayout.Item(key: "c", estimatedHeight: 300),
        VirtualTranscriptLayout.Item(key: "d", estimatedHeight: 400),
    ]

    @Test func buildsMeasuredBottomRelativeGeometry() {
        let layout = VirtualTranscriptLayout(
            items: items,
            measuredHeights: ["b": 250],
            spacing: 10
        )

        #expect(layout.heights == [100, 250, 300, 400])
        #expect(layout.topOffsets == [0, 110, 370, 680])
        #expect(layout.bottomOffsets == [980, 720, 410, 0])
        #expect(layout.totalHeight == 1_080)
        #expect(layout.viewportTop(distanceFromBottom: 0, viewportHeight: 500) == 580)
    }

    @Test func findsVisibleRowsWithOverscan() {
        let layout = VirtualTranscriptLayout(items: items, measuredHeights: [:], spacing: 10)

        // The 250pt viewport spans the end of b and beginning of c.
        let distance = layout.distanceFromBottom(viewportTop: 250, viewportHeight: 250)
        #expect(layout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: 250,
            overscanCount: 1
        ) == 0..<4)
    }

    @Test func restoresRenderedWindowFromAnchorKey() {
        let layout = VirtualTranscriptLayout(items: items, measuredHeights: [:], spacing: 10)

        #expect(layout.renderedRange(anchorKey: "b", count: 2) == 1..<3)
        #expect(layout.renderedRange(anchorKey: "d", count: 3) == 3..<4)
        #expect(layout.renderedRange(anchorKey: "missing", count: 2) == nil)
    }

    @Test func bottomDistanceSurvivesPrependingRows() {
        let original = VirtualTranscriptLayout(items: items, measuredHeights: [:], spacing: 10)
        let viewportHeight: CGFloat = 250
        let originalTop: CGFloat = 145
        let distance = original.distanceFromBottom(
            viewportTop: originalTop,
            viewportHeight: viewportHeight
        )

        let prepended = VirtualTranscriptLayout(
            items: [
                .init(key: "older-1", estimatedHeight: 500),
                .init(key: "older-2", estimatedHeight: 150),
            ] + items,
            measuredHeights: [:],
            spacing: 10
        )
        let restoredTop = prepended.viewportTop(
            distanceFromBottom: distance,
            viewportHeight: viewportHeight
        )

        #expect(restoredTop == 815)
        #expect(restoredTop - originalTop == 670)
    }

    @Test func measurementRebuildPreservesBottomDistance() {
        let initial = VirtualTranscriptLayout(items: items, measuredHeights: [:], spacing: 10)
        let viewportHeight: CGFloat = 250
        let distance = initial.distanceFromBottom(
            viewportTop: 350,
            viewportHeight: viewportHeight
        )

        let measured = VirtualTranscriptLayout(
            items: items,
            measuredHeights: ["a": 180, "b": 260],
            spacing: 10
        )
        let restoredTop = measured.viewportTop(
            distanceFromBottom: distance,
            viewportHeight: viewportHeight
        )

        #expect(restoredTop == 490)
    }

    @Test func anchorCompensationIgnoresChangesAboveTheViewport() {
        let initial = VirtualTranscriptLayout(items: items, measuredHeights: [:], spacing: 10)
        let measured = VirtualTranscriptLayout(
            items: items,
            measuredHeights: ["a": 180],
            spacing: 10
        )

        let distance = measured.distanceFromBottom(
            preservingAnchor: "c",
            previousLayout: initial,
            previousDistanceFromBottom: 120
        )

        #expect(distance == 120)
    }

    @Test func anchorCompensationOffsetsGrowthBelowTheViewport() {
        let initial = VirtualTranscriptLayout(items: items, measuredHeights: [:], spacing: 10)
        let measured = VirtualTranscriptLayout(
            items: items,
            measuredHeights: ["d": 520],
            spacing: 10
        )

        let distance = measured.distanceFromBottom(
            preservingAnchor: "b",
            previousLayout: initial,
            previousDistanceFromBottom: 120
        )

        #expect(distance == 240)
        #expect(initial.viewportTop(distanceFromBottom: 120, viewportHeight: 250)
            == measured.viewportTop(distanceFromBottom: distance ?? 0, viewportHeight: 250))
    }
}
