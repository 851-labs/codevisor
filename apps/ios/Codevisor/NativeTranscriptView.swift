import CodevisorCore
import SwiftUI

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
        measurementRevision: Int = 0
    ) {
        self.id = id
        self.content = content
        self.estimatedHeight = estimatedHeight
        self.measurementRevision = measurementRevision
        self.layoutKey = id.layoutKey
    }
}

struct TranscriptScrollCommand: Equatable {
    var token = 0
}

/// SwiftUI boundary around the UIKit virtualizer. All high-frequency geometry
/// and row mounting stays in UIKit; SwiftUI receives only viewport snapshots
/// and boundary transitions.
struct NativeTranscriptView: UIViewRepresentable {
    let rows: [TranscriptVirtualRow]
    let initialState: SessionScrollState?
    let followsLatest: Bool
    let hasOlderHistory: Bool
    let layoutFingerprint: Int
    let scrollCommand: TranscriptScrollCommand
    let sendAnimationRequest: UserSendAnimationRequest?
    let reduceMotion: Bool
    let claimSendAnimation: @MainActor (UserSendAnimationRequest) -> Bool
    let rowContent: @MainActor (TranscriptVirtualRow) -> AnyView
    let onViewportChange: @MainActor (SessionScrollState) -> Void
    let onBottomStateChange: @MainActor (Bool) -> Void
    let onFollowStateChange: @MainActor (Bool) -> Void
    let onNearTop: @MainActor () -> Void

    func makeUIView(context: Context) -> CollectionTranscriptView {
        let view = CollectionTranscriptView()
        configure(view)
        return view
    }

    func updateUIView(_ view: CollectionTranscriptView, context: Context) {
        configure(view)
    }

    static func dismantleUIView(
        _ view: CollectionTranscriptView,
        coordinator: Void
    ) {
        view.prepareForDismantle()
    }

    private func configure(_ view: CollectionTranscriptView) {
        view.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            reduceMotion: reduceMotion,
            claimSendAnimation: claimSendAnimation,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop
        )
    }
}
