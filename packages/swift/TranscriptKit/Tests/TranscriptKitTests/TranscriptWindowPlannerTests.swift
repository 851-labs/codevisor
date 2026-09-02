import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptWindowPlannerTests {
    private func layout(count: Int, height: CGFloat = 100) -> VirtualTranscriptLayout {
        VirtualTranscriptLayout(
            items: (0..<count).map { .init(key: "row-\($0)", estimatedHeight: height) },
            measuredHeights: [:],
            spacing: 0
        )
    }

    private let planner = TranscriptWindowPlanner(
        policy: TranscriptVirtualWindowPolicy(),
        initialRunwayViewportCount: 1.5
    )

    @Test func usesSymmetricInitialRunwayUntilPresentationIsReady() {
        let l = layout(count: 40)
        let range = planner.plannedRange(
            layout: l,
            distanceFromBottom: 0,
            viewportHeight: 200,
            scrollDelta: 500,
            isInitialPresentationReady: false,
            currentTargetKeys: ["row-0"]
        )
        let expected = l.visibleRange(
            distanceFromBottom: 0, viewportHeight: 200, runwayBefore: 300, runwayAfter: 300
        )
        #expect(range == expected)
        // Bottom 200pt viewport + 300pt runway above = 5 rows of 100.
        #expect(range == 35..<40)
    }

    @Test func delegatesToPolicyWithContiguousCurrentWindowOnceReady() {
        let l = layout(count: 40)
        let current: Set<String> = [
            "row-30", "row-31", "row-32", "row-33", "row-34", "row-35", "row-36", "row-37", "row-38", "row-39",
        ]
        let range = planner.plannedRange(
            layout: l,
            distanceFromBottom: 0,
            viewportHeight: 200,
            scrollDelta: 0,
            isInitialPresentationReady: true,
            currentTargetKeys: current
        )
        let expected = planner.policy.targetRange(
            layout: l,
            distanceFromBottom: 0,
            viewportHeight: 200,
            scrollDelta: 0,
            currentRange: 30..<40
        )
        #expect(range == expected)
        // A non-contiguous current window is treated as none.
        let broken = planner.plannedRange(
            layout: l,
            distanceFromBottom: 0,
            viewportHeight: 200,
            scrollDelta: 0,
            isInitialPresentationReady: true,
            currentTargetKeys: ["row-30", "row-39"]
        )
        #expect(
            broken
                == planner.policy.targetRange(
                    layout: l, distanceFromBottom: 0, viewportHeight: 200, scrollDelta: 0, currentRange: nil
                ))
    }

    @Test func targetKeysAlwaysCoverTheVisibleRange() {
        let l = layout(count: 10)
        let keys = TranscriptWindowPlanner.targetKeys(layout: l, targetRange: 0..<2, visibleRange: 7..<12)
        #expect(keys == ["row-0", "row-1", "row-7", "row-8", "row-9"])
        #expect(TranscriptWindowPlanner.targetKeys(layout: l, targetRange: 3..<3, visibleRange: 3..<3).isEmpty)
    }
}
