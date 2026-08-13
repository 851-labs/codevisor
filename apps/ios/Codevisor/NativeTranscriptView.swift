import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import UIKit

/// Stable rows consumed by the native iOS transcript virtualizer. Settled
/// content is immutable; the active row observes the controller from its own
/// hosting subtree so streaming never diffs the complete conversation.
struct TranscriptVirtualRow: Identifiable, Equatable {
    enum ID: Hashable {
        case message(UUID)
        case assistantPlanning(UUID)
        case plan(UUID)
        case assistantResult(UUID)
        case active
        case setup
        case backgroundTask
        case updateGate
        case connecting
        case serverWait
        case error
        case statusError
        case bottomSpacer

        var layoutKey: String {
            switch self {
            case let .message(id): "message:\(id.uuidString)"
            case let .assistantPlanning(id): "message:\(id.uuidString):planning"
            case let .plan(id): "message:\(id.uuidString):plan"
            case let .assistantResult(id): "message:\(id.uuidString):result"
            case .active: "special:active"
            case .setup: "special:setup"
            case .backgroundTask: "special:background"
            case .updateGate: "special:update-gate"
            case .connecting: "special:connecting"
            case .serverWait: "special:server-wait"
            case .error: "special:error"
            case .statusError: "special:status-error"
            case .bottomSpacer: "special:bottom-spacer"
            }
        }

        var isCacheableSettledRow: Bool {
            switch self {
            case .message, .assistantPlanning, .plan, .assistantResult: true
            case .active, .setup, .backgroundTask, .updateGate, .connecting, .serverWait,
                 .error, .statusError, .bottomSpacer: false
            }
        }

        var isPlanDocument: Bool {
            if case .plan = self { true } else { false }
        }
    }

    enum Content: Equatable {
        case message(ConversationItem, waitingOnBackgroundTask: String?)
        case assistantPlanning(AssistantMessage)
        case planDocument(String)
        case assistantResult(AssistantMessage, waitingOnBackgroundTask: String?)
        case active
        case setup([SessionSetupPhase])
        case optimistic(UserMessage, showsStartingAgent: Bool)
        case backgroundTask(String)
        case updateGate(String)
        case connecting(String)
        case serverWait(String)
        case error(String)
        case bottomSpacer(CGFloat)
    }

    let id: ID
    let content: Content
    let estimatedHeight: CGFloat
    let measurementRevision: Int
    let layoutKey: String

    var isUserMessage: Bool {
        switch content {
        case let .message(item, waitingOnBackgroundTask: _):
            if case .user = item { return true }
            return false
        case .optimistic:
            return true
        default:
            return false
        }
    }

    init(
        id: ID,
        content: Content,
        estimatedHeight: CGFloat,
        measurementRevision: Int = 0,
    ) {
        self.id = id
        self.content = content
        self.estimatedHeight = estimatedHeight
        self.measurementRevision = measurementRevision
        layoutKey = id.layoutKey
    }
}

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
    let layoutFingerprint: Int
    let scrollCommand: TranscriptScrollCommand
    let sendAnimationRequest: UserSendAnimationRequest?
    let sendAnimationSourceFrame: CGRect?
    let presentationRole: TranscriptPresentationRole
    let reduceMotion: Bool
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
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            sendAnimationSourceFrame: sendAnimationSourceFrame,
            presentationRole: presentationRole,
            reduceMotion: reduceMotion,
            claimSendAnimation: claimSendAnimation,
            onSendAnimationStarted: onSendAnimationStarted,
            onSendAnimationCompleted: onSendAnimationCompleted,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop,
        )
    }
}
