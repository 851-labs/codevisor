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
        #expect(TranscriptSendAnimationContract.presentationSafetyDuration == 0.71)
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

    @Test("A new assistant stays hidden from pending handoff through active flight")
    func holdsNewAssistantAcrossTheWholeHandoff() {
        for phase in [
            TranscriptSendPresentationPhase.pending,
            TranscriptSendPresentationPhase.active,
        ] {
            #expect(
                TranscriptSendAnimationContract.shouldHoldAssistantRow(
                    phase: phase,
                    rowIsActive: true,
                    rowExistedBeforeSend: false
                ))
        }

        #expect(
            !TranscriptSendAnimationContract.shouldHoldAssistantRow(
                phase: .idle,
                rowIsActive: true,
                rowExistedBeforeSend: false
            ))
        #expect(
            !TranscriptSendAnimationContract.shouldHoldAssistantRow(
                phase: .pending,
                rowIsActive: true,
                rowExistedBeforeSend: true
            ))
        #expect(
            !TranscriptSendAnimationContract.shouldHoldAssistantRow(
                phase: .pending,
                rowIsActive: false,
                rowExistedBeforeSend: false
            ))
    }

    @Test("Existing history is locked only while final send geometry is pending")
    func holdsHistoryBeforeTheFlightBegins() {
        #expect(
            TranscriptSendAnimationContract.shouldHoldHistoryRow(
                phase: .pending,
                rowExistedBeforeSend: true,
                translationY: 84
            ))
        #expect(
            !TranscriptSendAnimationContract.shouldHoldHistoryRow(
                phase: .active,
                rowExistedBeforeSend: true,
                translationY: 84
            ))
        #expect(
            !TranscriptSendAnimationContract.shouldHoldHistoryRow(
                phase: .pending,
                rowExistedBeforeSend: false,
                translationY: 84
            ))
        #expect(
            !TranscriptSendAnimationContract.shouldHoldHistoryRow(
                phase: .pending,
                rowExistedBeforeSend: true,
                translationY: 0.5
            ))
    }

    @Test("Presentation completion is token scoped and idempotent")
    func tokenScopedCompletion() {
        var lifecycle = TranscriptSendPresentationLifecycle()
        lifecycle.begin(token: 1, at: 10)
        lifecycle.begin(token: 2, at: 10.1)

        let staleCompletion = lifecycle.complete(token: 1)
        #expect(!staleCompletion)
        #expect(lifecycle.activeToken == 2)
        let currentCompletion = lifecycle.complete(token: 2)
        #expect(currentCompletion)
        let repeatedCompletion = lifecycle.complete(token: 2)
        #expect(!repeatedCompletion)
        #expect(lifecycle.activeToken == nil)
    }

    @Test("Presentation watchdog uses an injected deterministic clock")
    func deterministicWatchdog() {
        var lifecycle = TranscriptSendPresentationLifecycle()
        let deadline = lifecycle.begin(token: 7, at: 20)

        #expect(deadline == 20.71)
        #expect(!lifecycle.isExpired(token: 7, at: deadline - 0.001))
        #expect(lifecycle.isExpired(token: 7, at: deadline))
        #expect(!lifecycle.isExpired(token: 8, at: deadline + 1))
    }

    @Test("Cancellation returns ownership once and leaves the lifecycle idle")
    func cancellationIsIdempotent() {
        var lifecycle = TranscriptSendPresentationLifecycle()
        lifecycle.begin(token: 11, at: 30)

        let cancellation = lifecycle.cancel()
        #expect(cancellation == 11)
        let repeatedCancellation = lifecycle.cancel()
        #expect(repeatedCancellation == nil)
        #expect(lifecycle.activeToken == nil)
        #expect(lifecycle.deadline == nil)
    }
}
