import CoreGraphics
import Testing
@testable import CodevisorUI

@Suite("Transcript send animation")
struct TranscriptSendAnimationTests {
    @Test("The row lifts from the editor center without changing its geometry")
    func usesFinalRowGeometry() throws {
        let sourceFrame = CGRect(x: 24, y: 640, width: 354, height: 30)
        let compactTarget = CGRect(x: 250, y: 136, width: 124, height: 38)
        let multilineTarget = CGRect(x: 80, y: 136, width: 294, height: 114)

        let compactPlan = try #require(
            TranscriptSendAnimationContract.plan(
                sourceY: sourceFrame.midY,
                targetY: compactTarget.minY
            ))
        let multilinePlan = try #require(
            TranscriptSendAnimationContract.plan(
                sourceY: sourceFrame.midY,
                targetY: multilineTarget.minY
            ))

        #expect(compactPlan.translationY == 519)
        #expect(multilinePlan == compactPlan)
    }

    @Test("Every send uses the established timing curve")
    func usesCanonicalTiming() throws {
        let plan = try #require(
            TranscriptSendAnimationContract.plan(
                sourceY: 655,
                targetY: 136
            ))

        #expect(plan.duration == 0.46)
        #expect(plan.fadeDuration == 0.12)
        #expect(plan.controlPoint1 == CGPoint(x: 0.22, y: 1))
        #expect(plan.controlPoint2 == CGPoint(x: 0.36, y: 1))
    }

    @Test("Reduce Motion and non-upward travel do not create a lift")
    func skipsInapplicableMotion() {
        #expect(
            TranscriptSendAnimationContract.plan(
                sourceY: 655,
                targetY: 136,
                reduceMotion: true
            ) == nil)
        #expect(
            TranscriptSendAnimationContract.plan(
                sourceY: 136,
                targetY: 136
            ) == nil)
        #expect(
            TranscriptSendAnimationContract.plan(
                sourceY: 120,
                targetY: 136
            ) == nil)
    }
}
