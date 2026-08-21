import CoreGraphics
import Testing
@testable import TranscriptKit

struct VirtualTranscriptLayoutTests {
    @Test func retainedRowsCanAnimateAcrossAnInstantBottomJump() throws {
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

        #expect(
            TranscriptSendHistoryTransition.translationY(
                forKey: "assistant",
                from: previous,
                to: current
            ) == 140
        )
        #expect(
            TranscriptSendHistoryTransition.translationY(
                forKey: "spacer",
                from: previous,
                to: current
            ) == 0
        )
        #expect(
            TranscriptSendHistoryTransition.translationY(
                forKey: "user",
                from: previous,
                to: current
            ) == nil
        )
    }

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
        #expect(
            layout.visibleRange(
                distanceFromBottom: distance,
                viewportHeight: 250,
                overscanCount: 1
            ) == 0..<4)
    }

    @Test func geometryRunwayPreparesConsistentScrollDistance() {
        let rows = (0..<20).map {
            VirtualTranscriptLayout.Item(key: "message:\($0)", estimatedHeight: 100)
        }
        let layout = VirtualTranscriptLayout(items: rows, measuredHeights: [:], spacing: 0)
        let viewportHeight: CGFloat = 400
        let distance = layout.distanceFromBottom(
            viewportTop: 800,
            viewportHeight: viewportHeight
        )

        let range = layout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: viewportHeight,
            runwayBefore: viewportHeight * 1.5,
            runwayAfter: viewportHeight * 1.5
        )

        #expect(range == 2..<18)
    }

    @Test func bottomRunwayWarmsRowsAboveTheInitialViewport() {
        let rows = (0..<30).map {
            VirtualTranscriptLayout.Item(key: "message:\($0)", estimatedHeight: 100)
        }
        let layout = VirtualTranscriptLayout(items: rows, measuredHeights: [:], spacing: 0)

        let range = layout.visibleRange(
            distanceFromBottom: 0,
            viewportHeight: 600,
            runwayBefore: 900,
            runwayAfter: 900
        )

        #expect(range == 15..<30)
    }

    @Test func heavyBoundaryStopsOverscanFromMountingItsFarSide() {
        #expect(
            VirtualTranscriptLayout.overscanRange(
                visibleRange: 1..<2,
                overscannedRange: 0..<4,
                stoppingAt: [2]
            ) == 1..<3)
        #expect(
            VirtualTranscriptLayout.overscanRange(
                visibleRange: 3..<4,
                overscannedRange: 1..<5,
                stoppingAt: [2]
            ) == 2..<4)
    }

    @Test func visibleHeavyBoundaryDisablesAdjacentOverscan() {
        #expect(
            VirtualTranscriptLayout.overscanRange(
                visibleRange: 2..<3,
                overscannedRange: 0..<5,
                stoppingAt: [2]
            ) == 2..<3)
        #expect(
            VirtualTranscriptLayout.overscanRange(
                visibleRange: 2..<3,
                overscannedRange: 0..<5,
                stoppingAt: []
            ) == 0..<5)
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

    @Test func incrementalMeasurementProducesOneNonOverlappingGeometrySnapshot() throws {
        let initial = VirtualTranscriptLayout(items: items, measuredHeights: [:], spacing: 10)
        let measured = try #require(initial.updatingHeight(forKey: "b", to: 460))

        #expect(measured.heights == [100, 460, 300, 400])
        #expect(measured.topOffsets == [0, 110, 580, 890])
        #expect(measured.totalHeight == 1_290)

        for index in 0..<(measured.keys.count - 1) {
            #expect(
                measured.topOffsets[index] + measured.heights[index] + 10
                    == measured.topOffsets[index + 1]
            )
        }

        let viewportHeight: CGFloat = 250
        let previousDistanceFromBottom: CGFloat = 120
        let nextDistanceFromBottom = try #require(
            measured.distanceFromBottom(
                preservingAnchor: "c",
                previousLayout: initial,
                previousDistanceFromBottom: previousDistanceFromBottom
            ))
        let previousAnchorY =
            initial.topOffsets[2]
            - initial.viewportTop(
                distanceFromBottom: previousDistanceFromBottom,
                viewportHeight: viewportHeight
            )
        let nextAnchorY =
            measured.topOffsets[2]
            - measured.viewportTop(
                distanceFromBottom: nextDistanceFromBottom,
                viewportHeight: viewportHeight
            )

        #expect(nextAnchorY == previousAnchorY)
    }

    @Test func uncachedOpeningStaysAtBottomAcrossHydrationAndMeasurement() {
        let placeholder = VirtualTranscriptLayout(
            items: [.init(key: "bottom-spacer", estimatedHeight: 120)],
            measuredHeights: ["bottom-spacer": 120],
            spacing: 20
        )
        #expect(
            placeholder.distanceFromBottom(
                viewportTop: placeholder.viewportTop(distanceFromBottom: 0, viewportHeight: 600),
                viewportHeight: 600
            ) == 0)

        let hydratedItems =
            (0..<12).map {
                VirtualTranscriptLayout.Item(key: "message:\($0)", estimatedHeight: 180)
            } + [.init(key: "bottom-spacer", estimatedHeight: 120)]
        let hydrated = VirtualTranscriptLayout(
            items: hydratedItems,
            measuredHeights: ["bottom-spacer": 120],
            spacing: 20
        )
        let measured = VirtualTranscriptLayout(
            items: hydratedItems,
            measuredHeights: [
                "message:9": 420,
                "message:10": 260,
                "bottom-spacer": 120,
            ],
            spacing: 20
        )

        for layout in [hydrated, measured] {
            let top = layout.viewportTop(distanceFromBottom: 0, viewportHeight: 600)
            #expect(
                layout.distanceFromBottom(
                    viewportTop: top,
                    viewportHeight: 600
                ) == 0)
        }
    }

    @Test func bottomVirtualWindowDoesNotMountTheWholeTranscript() {
        let longItems = (0..<100).map {
            VirtualTranscriptLayout.Item(key: "message:\($0)", estimatedHeight: 100)
        }
        let layout = VirtualTranscriptLayout(
            items: longItems,
            measuredHeights: [:],
            spacing: 20
        )

        let range = layout.visibleRange(
            distanceFromBottom: 0,
            viewportHeight: 600,
            overscanCount: 2
        )

        #expect(range.upperBound == longItems.count)
        #expect(range.lowerBound > 90)
        #expect(range.count < 10)
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
        #expect(
            initial.viewportTop(distanceFromBottom: 120, viewportHeight: 250)
                == measured.viewportTop(distanceFromBottom: distance ?? 0, viewportHeight: 250))
    }

    @Test func insetViewportPreservesUIKitTopAndBottomCoordinates() {
        let viewport = VirtualTranscriptViewport(
            contentHeight: 2_000,
            viewportHeight: 800,
            topInset: 100
        )

        #expect(viewport.minimumOffsetY == -100)
        #expect(viewport.maximumOffsetY == 1_200)
        #expect(viewport.maximumDistanceFromBottom == 1_300)
        #expect(viewport.distanceFromTop(offsetY: -100) == 0)
        #expect(viewport.distanceFromBottom(offsetY: -100) == 1_300)
        #expect(viewport.offsetY(distanceFromBottom: 1_300) == -100)
        #expect(viewport.offsetY(distanceFromBottom: 0) == 1_200)
    }

    @Test func insetViewportClampsShortDocumentsToOneStableCoordinate() {
        let viewport = VirtualTranscriptViewport(
            contentHeight: 300,
            viewportHeight: 800,
            topInset: 96
        )

        #expect(viewport.minimumOffsetY == -96)
        #expect(viewport.maximumOffsetY == -96)
        #expect(viewport.maximumDistanceFromBottom == 0)
        #expect(viewport.boundedOffsetY(500) == -96)
        #expect(viewport.distanceFromBottom(offsetY: 500) == 0)
    }

}
