import CoreGraphics
import Testing
@testable import TranscriptKit

struct TranscriptVirtualWindowPolicyTests {
    private let policy = TranscriptVirtualWindowPolicy()
    private let layout = VirtualTranscriptLayout(
        items: (0..<40).map {
            .init(key: "row:\($0)", estimatedHeight: 100, spacingAfter: 0)
        },
        measuredHeights: [:],
        spacing: 0
    )

    @Test func keepsPreparedWindowWhileViewportRemainsInsideGuardBand() {
        let distance = layout.distanceFromBottom(viewportTop: 1_000, viewportHeight: 400)
        let current = 4..<20

        #expect(
            policy.targetRange(
                layout: layout,
                distanceFromBottom: distance,
                viewportHeight: 400,
                scrollDelta: 50,
                currentRange: current
            ) == current)
    }

    @Test func projectedMotionAdvancesWindowBeforeViewportReachesStaticGuard() {
        let distance = layout.distanceFromBottom(viewportTop: 1_000, viewportHeight: 400)
        let target = policy.targetRange(
            layout: layout,
            distanceFromBottom: distance,
            viewportHeight: 400,
            scrollDelta: 400,
            currentRange: 4..<20
        )

        #expect(target == 5..<36)
    }

    @Test func advancesToDirectionallyBiasedPixelRunwayAfterGuardBand() {
        let distance = layout.distanceFromBottom(viewportTop: 1_000, viewportHeight: 400)
        let target = policy.targetRange(
            layout: layout,
            distanceFromBottom: distance,
            viewportHeight: 400,
            scrollDelta: 100,
            currentRange: 10..<16
        )

        #expect(target == 5..<29)
    }

    @Test func fastScrollAddsBoundedRunwayInDirectionOfTravel() {
        let distance = layout.distanceFromBottom(viewportTop: 2_000, viewportHeight: 400)
        let down = policy.targetRange(
            layout: layout,
            distanceFromBottom: distance,
            viewportHeight: 400,
            scrollDelta: 1_000,
            currentRange: nil
        )
        let up = policy.targetRange(
            layout: layout,
            distanceFromBottom: distance,
            viewportHeight: 400,
            scrollDelta: -1_000,
            currentRange: nil
        )

        #expect(down == 15..<40)
        #expect(up == 0..<29)
    }

    @Test func mountPlanSeparatesMandatoryViewportFromDirectionalRunway() {
        #expect(
            policy.mountPlan(
                targetRange: 2..<10,
                visibleRange: 5..<7,
                scrollDelta: -20
            )
                == TranscriptVirtualWindowMountPlan(
                    visibleIndices: [5, 6],
                    runwayIndices: [4, 3, 2, 7, 8, 9]
                ))
        #expect(
            policy.mountPlan(
                targetRange: 2..<10,
                visibleRange: 5..<7,
                scrollDelta: 20
            )
                == TranscriptVirtualWindowMountPlan(
                    visibleIndices: [5, 6],
                    runwayIndices: [7, 8, 9, 4, 3, 2]
                ))
    }

    @Test func mountPlanKeepsViewportMandatoryWhenTargetHasFallenBehind() {
        #expect(
            policy.mountPlan(
                targetRange: 2..<5,
                visibleRange: 8..<10,
                scrollDelta: 100
            )
                == TranscriptVirtualWindowMountPlan(
                    visibleIndices: [8, 9],
                    runwayIndices: [4, 3, 2]
                ))
    }

    @Test func handoffRetainsLastReadyWindowAndDropsAbandonedIntermediateTarget() {
        var handoff = TranscriptVirtualWindowHandoff()
        handoff.setTarget(["a", "b"])
        #expect(handoff.promoteIfReady { _ in true })
        #expect(handoff.presentedKeys == ["a", "b"])

        handoff.setTarget(["c", "d"])
        #expect(!handoff.promoteIfReady { $0 == "c" })
        #expect(handoff.retainedKeys == ["a", "b", "c", "d"])

        handoff.setTarget(["e", "f"])
        #expect(handoff.retainedKeys == ["a", "b", "e", "f"])
        #expect(handoff.promoteIfReady { _ in true })
        #expect(handoff.retainedKeys == ["e", "f"])
    }

    @Test func runwayMotionProjectsDirectionAcrossDisplayFramesAndExpires() {
        var motion = TranscriptRunwayMotion()
        motion.observe(viewportTop: 1_000, timestamp: 1)
        motion.observe(viewportTop: 1_200, timestamp: 1.05)

        let immediate = motion.projectedDelta(timestamp: 1.05, maximumDistance: 500)
        let followUp = motion.projectedDelta(timestamp: 1.15, maximumDistance: 500)

        #expect(immediate > 0)
        #expect(followUp > 0)
        #expect(followUp < immediate)
        #expect(motion.projectedDelta(timestamp: 1.30, maximumDistance: 500) == 0)
    }

    @Test func runwayMotionChangesDirectionImmediatelyAndClampsProjection() {
        var motion = TranscriptRunwayMotion()
        motion.observe(viewportTop: 1_000, timestamp: 1)
        motion.observe(viewportTop: 1_500, timestamp: 1.01)
        #expect(motion.projectedDelta(timestamp: 1.01, maximumDistance: 300) == 300)

        motion.observe(viewportTop: 1_400, timestamp: 1.02)
        #expect(motion.projectedDelta(timestamp: 1.02, maximumDistance: 300) == -300)
    }
}
