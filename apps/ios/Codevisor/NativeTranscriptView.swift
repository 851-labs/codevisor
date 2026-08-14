import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import UIKit

/// UIKit only mounts and measures projected rows. The transcript-wide row
/// construction itself lives in CodevisorCore and runs off the UI actor.
typealias TranscriptVirtualRow = TranscriptPresentationRow

struct TranscriptScrollCommand: Equatable {
    var token = 0
}

/// A promoted new chat briefly has two transcript surfaces backed by the same
/// controller: the visible sheet and the workspace being mounted beneath it.
/// Only the foreground surface may consume presentation events or publish
/// viewport state; the prewarming surface is limited to layout and measurement.
enum TranscriptPresentationRole: Equatable {
    case foreground
    case prewarming
}

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

/// The real virtualized row is the animation visual for a promoted first
/// send. Its snapshot and final window-space frame let the presentation layer
/// reuse the ordinary row animation without inventing another bubble view.
@MainActor
struct TranscriptSendAnimationTarget {
    let rowFrame: CGRect
    let rowSnapshot: UIView
}

/// SwiftUI boundary around the UIKit virtualizer. One dedicated container
/// controller owns every row host, keeping transcript content out of the
/// surrounding navigation controller's containment tree.
struct NativeTranscriptView: UIViewControllerRepresentable {
    let rows: [TranscriptVirtualRow]
    let initialState: SessionScrollState?
    let followsLatest: Bool
    let hasOlderHistory: Bool
    let showsOlderHistoryLoadingIndicator: Bool
    let olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?
    let isLoadingInitialHistory: Bool
    let layoutFingerprint: Int
    let scrollCommand: TranscriptScrollCommand
    let sendAnimationRequest: UserSendAnimationRequest?
    let sendAnimationSourceFrame: CGRect?
    let presentationRole: TranscriptPresentationRole
    let reduceMotion: Bool
    let scrollIndicatorBottomInset: CGFloat
    let claimSendAnimation: @MainActor (UserSendAnimationRequest) -> Bool
    let onSendAnimationStarted: (@MainActor (
        UserSendAnimationRequest,
        TranscriptSendAnimationTarget
    ) -> Bool)?
    let onSendAnimationCompleted: @MainActor (UserSendAnimationRequest) -> Void
    let rowContent: @MainActor (TranscriptVirtualRow) -> AnyView
    let onViewportChange: @MainActor (SessionScrollState) -> Void
    let onBottomStateChange: @MainActor (Bool) -> Void
    let onFollowStateChange: @MainActor (Bool) -> Void
    let onNearTop: @MainActor () -> Void
    let onOlderHistoryPresented: @MainActor (UInt64) -> Void

    func makeUIViewController(context _: Context) -> TranscriptViewController {
        let controller = TranscriptViewController()
        configure(controller)
        return controller
    }

    func updateUIViewController(
        _ controller: TranscriptViewController,
        context _: Context,
    ) {
        configure(controller)
    }

    static func dismantleUIViewController(
        _ controller: TranscriptViewController,
        coordinator _: Void,
    ) {
        controller.prepareForDismantle()
    }

    private func configure(_ controller: TranscriptViewController) {
        controller.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            showsOlderHistoryLoadingIndicator: showsOlderHistoryLoadingIndicator,
            olderHistoryPresentationTarget: olderHistoryPresentationTarget,
            isLoadingInitialHistory: isLoadingInitialHistory,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            sendAnimationSourceFrame: sendAnimationSourceFrame,
            presentationRole: presentationRole,
            reduceMotion: reduceMotion,
            scrollIndicatorBottomInset: scrollIndicatorBottomInset,
            claimSendAnimation: claimSendAnimation,
            onSendAnimationStarted: onSendAnimationStarted,
            onSendAnimationCompleted: onSendAnimationCompleted,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop,
            onOlderHistoryPresented: onOlderHistoryPresented,
        )
    }
}
