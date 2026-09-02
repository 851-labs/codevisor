import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import UIKit

enum TranscriptSendAnimationMetrics {
    static let duration = TranscriptSendAnimationContract.duration

    static func plan(
        sourceY: CGFloat,
        targetY: CGFloat,
        reduceMotion: Bool = false
    ) -> TranscriptSendAnimationPlan? {
        TranscriptSendAnimationContract.plan(
            sourceY: sourceY,
            targetY: targetY,
            reduceMotion: reduceMotion
        )
    }

    /// Creates a fresh Core Animation group from the shared motion plan.
    /// Ordinary rows and the cross-sheet snapshot both call this factory, so
    /// their position, fade, duration, and easing cannot drift apart.
    static func layerAnimation(
        plan: TranscriptSendAnimationPlan,
        fadesIn: Bool
    ) -> CAAnimationGroup {
        let movement = CABasicAnimation(keyPath: "transform.translation.y")
        movement.fromValue = plan.translationY
        movement.toValue = 0
        movement.duration = plan.duration
        movement.timingFunction = CAMediaTimingFunction(
            controlPoints: Float(plan.controlPoint1.x),
            Float(plan.controlPoint1.y),
            Float(plan.controlPoint2.x),
            Float(plan.controlPoint2.y)
        )

        let animations: [CAAnimation]
        if fadesIn {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = plan.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animations = [movement, fade]
        } else {
            animations = [movement]
        }

        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = plan.duration
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true
        return group
    }

    static var propertyTimingParameters: UICubicTimingParameters {
        UICubicTimingParameters(
            controlPoint1: TranscriptSendAnimationContract.controlPoint1,
            controlPoint2: TranscriptSendAnimationContract.controlPoint2
        )
    }
}

/// SwiftUI boundary around the UIKit virtualizer. One dedicated container
/// controller owns every row host, keeping transcript content out of the
/// surrounding navigation controller's containment tree.
struct NativeTranscriptView: UIViewControllerRepresentable {
    let input: TranscriptSurfaceInput
    let callbacks: TranscriptSurfaceCallbacks

    func makeUIViewController(context _: Context) -> TranscriptViewController {
        let controller = TranscriptViewController()
        controller.configure(input, callbacks: callbacks)
        return controller
    }

    func updateUIViewController(
        _ controller: TranscriptViewController,
        context _: Context,
    ) {
        controller.configure(input, callbacks: callbacks)
    }

    static func dismantleUIViewController(
        _ controller: TranscriptViewController,
        coordinator _: Void,
    ) {
        controller.prepareForDismantle()
    }
}
