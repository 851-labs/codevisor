import CoreGraphics
import CodevisorProtocol
import Foundation

/// Immutable transcript input copied from the UI actor before row projection.
/// All expensive, transcript-wide work operates on this value on the
/// projection actor; AppKit/UIKit only mount the resulting visible rows.
public struct TranscriptProjectionInput: Sendable {
    public enum ConnectionStatus: Equatable, Sendable {
        case idle
        case connecting(String)
        case failed(String)
    }

    public let settledConversation: [ConversationItem]
    public let pendingUserMessage: UserMessage?
    /// Immutable value represented by the projected active row. The native
    /// row may observe newer token content only while the live item keeps this
    /// identity; at a turn boundary this snapshot keeps the old response on
    /// screen until the replacement projection commits.
    public let activeItem: ConversationItem?
    public var hasActiveItem: Bool { activeItem != nil }
    public let setupPhases: [SessionSetupPhase]
    public let waitingBackgroundTaskDescription: String?
    public let waitingHarnessUpdateName: String?
    public let isLoadingInitialHistory: Bool
    public let serverWaitMessage: String?
    public let sessionErrorMessage: String?
    public let status: ConnectionStatus

    public init(
        settledConversation: [ConversationItem],
        pendingUserMessage: UserMessage?,
        activeItem: ConversationItem?,
        setupPhases: [SessionSetupPhase],
        waitingBackgroundTaskDescription: String?,
        waitingHarnessUpdateName: String?,
        isLoadingInitialHistory: Bool,
        serverWaitMessage: String?,
        sessionErrorMessage: String?,
        status: ConnectionStatus
    ) {
        self.settledConversation = settledConversation
        self.pendingUserMessage = pendingUserMessage
        self.activeItem = activeItem
        self.setupPhases = setupPhases
        self.waitingBackgroundTaskDescription = waitingBackgroundTaskDescription
        self.waitingHarnessUpdateName = waitingHarnessUpdateName
        self.isLoadingInitialHistory = isLoadingInitialHistory
        self.serverWaitMessage = serverWaitMessage
        self.sessionErrorMessage = sessionErrorMessage
        self.status = status
    }
}

/// A cheap version token. Copying the input above is copy-on-write; this key
/// lets SwiftUI cancel stale preparations without comparing the transcript.
public struct TranscriptProjectionKey: Hashable, Sendable {
    public let sessionID: UUID
    public let controllerRevision: UInt64
    public let modelRevision: UInt64

    public init(sessionID: UUID, controllerRevision: UInt64, modelRevision: UInt64) {
        self.sessionID = sessionID
        self.controllerRevision = controllerRevision
        self.modelRevision = modelRevision
    }
}

public struct TranscriptProjectionOptions: Hashable, Sendable {
    /// iOS presents the initial connection message inline. macOS keeps its
    /// existing quiet connection treatment while sharing every other row.
    public let includesConnectingRow: Bool
    /// Platform composer geometry. Supplying it here keeps the final O(n)
    /// array materialization on the projection actor too.
    public let bottomSpacerHeight: CGFloat?

    public init(includesConnectingRow: Bool, bottomSpacerHeight: CGFloat? = nil) {
        self.includesConnectingRow = includesConnectingRow
        self.bottomSpacerHeight = bottomSpacerHeight
    }
}

public struct TranscriptProjectionRequest: Hashable, Sendable {
    public let key: TranscriptProjectionKey
    public let options: TranscriptProjectionOptions

    public init(key: TranscriptProjectionKey, options: TranscriptProjectionOptions) {
        self.key = key
        self.options = options
    }
}

/// Stable, immutable rows shared by both native transcript virtualizers.
public struct TranscriptPresentationRow: Identifiable, Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case message(UUID)
        case assistantPlanning(UUID)
        case activePlanning(UUID)
        case plan(UUID)
        case planHeader(UUID)
        case activePlanHeader(UUID)
        case planMarkdown(UUID, ordinal: Int)
        case activePlanMarkdown(UUID, ordinal: Int)
        case assistantResult(UUID)
        case activeResult(UUID)
        case assistantChrome(UUID, TranscriptAssistantChromeSlice)
        case activeChrome(UUID, TranscriptAssistantChromeSlice)
        case assistantMarkdown(UUID, sourceID: String, ordinal: Int)
        case activeMarkdown(UUID, sourceID: String, ordinal: Int)
        case assistantAttachment(UUID, sourceID: String, ordinal: Int)
        case activeAttachment(UUID, sourceID: String, ordinal: Int)
        case active(UUID)
        case setup
        case backgroundTask
        case updateGate
        case connecting
        case serverWait
        case error
        case statusError
        case bottomSpacer

        public var layoutKey: String {
            switch self {
            case let .message(id): "message:\(id.uuidString)"
            case let .assistantPlanning(id), let .activePlanning(id):
                "message:\(id.uuidString):planning"
            case let .plan(id): "message:\(id.uuidString):plan"
            case let .planHeader(id), let .activePlanHeader(id):
                "message:\(id.uuidString):plan:header"
            case let .planMarkdown(id, ordinal), let .activePlanMarkdown(id, ordinal):
                "message:\(id.uuidString):plan:markdown:\(ordinal)"
            case let .assistantResult(id), let .activeResult(id):
                "message:\(id.uuidString):result"
            case let .assistantChrome(id, slice), let .activeChrome(id, slice):
                "message:\(id.uuidString):chrome:\(slice.layoutComponent)"
            case let .assistantMarkdown(id, sourceID, ordinal),
                let .activeMarkdown(id, sourceID, ordinal):
                "message:\(id.uuidString):markdown:\(sourceID):\(ordinal)"
            case let .assistantAttachment(id, sourceID, ordinal),
                let .activeAttachment(id, sourceID, ordinal):
                "message:\(id.uuidString):attachment:\(sourceID):\(ordinal)"
            // An ordinary assistant keeps the same native host and measurement
            // when it moves from the live slot into settled history.
            case let .active(id): "message:\(id.uuidString)"
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

        public var isCacheableSettledRow: Bool {
            switch self {
            case .message, .assistantPlanning, .plan, .planHeader, .planMarkdown,
                .assistantResult, .assistantChrome, .assistantMarkdown, .assistantAttachment:
                true
            case .active, .activePlanning, .activePlanHeader, .activePlanMarkdown,
                .activeResult, .activeChrome, .activeMarkdown, .activeAttachment, .setup,
                .backgroundTask, .updateGate, .connecting, .serverWait, .error,
                .statusError, .bottomSpacer:
                false
            }
        }

        public var isPlanDocument: Bool {
            if case .plan = self { true } else { false }
        }

        public var isActiveRow: Bool {
            switch self {
            case .active, .activePlanning, .activePlanHeader, .activePlanMarkdown,
                .activeResult, .activeChrome, .activeMarkdown, .activeAttachment:
                true
            default: false
            }
        }

        public var messageID: UUID? {
            switch self {
            case let .message(id), let .assistantPlanning(id), let .activePlanning(id),
                let .plan(id), let .planHeader(id), let .activePlanHeader(id),
                let .planMarkdown(id, _), let .activePlanMarkdown(id, _),
                let .assistantResult(id), let .activeResult(id), let .active(id):
                id
            case let .assistantChrome(id, _), let .activeChrome(id, _),
                let .assistantMarkdown(id, _, _), let .activeMarkdown(id, _, _),
                let .assistantAttachment(id, _, _), let .activeAttachment(id, _, _):
                id
            case .setup, .backgroundTask, .updateGate, .connecting, .serverWait, .error,
                .statusError, .bottomSpacer:
                nil
            }
        }
    }

    public enum Content: Equatable, Sendable {
        case message(ConversationItem, waitingOnBackgroundTask: String?)
        case assistantPlanning(AssistantMessage)
        case planDocument(String)
        case planHeader(lifecycle: TranscriptBlockLifecycle)
        case assistantResult(AssistantMessage, waitingOnBackgroundTask: String?)
        case assistantChrome(
            AssistantMessage,
            slice: TranscriptAssistantChromeSlice,
            waitingOnBackgroundTask: String?
        )
        case markdownBlock(TranscriptMarkdownBlock)
        case assistantAttachment(TranscriptAssistantAttachment)
        case active(ConversationItem)
        case setup([SessionSetupPhase])
        case optimistic(UserMessage, showsStartingAgent: Bool)
        case backgroundTask(String)
        case updateGate(String)
        case connecting(String)
        case serverWait(String)
        case error(String)
        case bottomSpacer(CGFloat)
    }

    public let id: ID
    public let content: Content
    public let estimatedHeight: CGFloat
    public let measurementRevision: Int
    public let layoutKey: String
    /// Overrides ordinary message spacing for adjacent blocks in one document.
    public let spacingAfter: CGFloat?
    /// The completed assistant item represented by this visible slice. The
    /// active slot can carry this after generation ends without changing its
    /// stable row identity.
    public let finishedResponseItemId: UUID?

    public var isUserMessage: Bool {
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

    public init(
        id: ID,
        content: Content,
        estimatedHeight: CGFloat,
        measurementRevision: Int = 0,
        spacingAfter: CGFloat? = nil,
        finishedResponseItemId: UUID? = nil
    ) {
        self.id = id
        self.content = content
        self.estimatedHeight = estimatedHeight
        self.measurementRevision = measurementRevision
        self.spacingAfter = spacingAfter
        layoutKey = id.layoutKey
        if let finishedResponseItemId {
            self.finishedResponseItemId = finishedResponseItemId
        } else {
            self.finishedResponseItemId =
                switch content {
                case let .message(item, waitingOnBackgroundTask: _):
                    if case let .assistant(message) = item { message.id } else { nil }
                case let .assistantResult(message, waitingOnBackgroundTask: _):
                    message.id
                case let .assistantChrome(message, slice, waitingOnBackgroundTask: _):
                    slice == .epilogue && !message.turn.isGenerating ? message.id : nil
                case .planHeader, .markdownBlock, .assistantAttachment:
                    nil
                case let .active(item):
                    if case let .assistant(message) = item, !message.turn.isGenerating {
                        message.id
                    } else {
                        nil
                    }
                default:
                    nil
                }
        }
    }
}

/// Resolves the value rendered by one identity-bound active row. A token flush
/// may use the live item, but a row from an older projection must keep showing
/// its own assistant after the model starts the next turn.
public enum TranscriptActiveItemResolver {
    public static func resolve(
        projected: ConversationItem,
        live: ConversationItem?,
        settled: [ConversationItem]
    ) -> ConversationItem {
        if live?.id == projected.id, let live {
            return live
        }
        if let settled = settled.last(where: { $0.id == projected.id }) {
            return settled
        }
        // A provider can replace the locally-created active id with its
        // canonical transcript id before the next projection arrives. Unlike
        // a turn boundary, the projected id is not settled in that case, so
        // keep rendering the live bubble instead of flashing its old snapshot.
        return live ?? projected
    }
}

/// Serializes and caches transcript projection away from the UI actor. A
/// cache hit makes revisiting a chat O(1); cancellation checks stop a rapid
/// sequence of sidebar taps from finishing obsolete transcript work.
public actor TranscriptRowProjectionCache {
    public static let shared = TranscriptRowProjectionCache()

    private struct CacheKey: Hashable {
        public let projection: TranscriptProjectionKey
        public let options: TranscriptProjectionOptions
    }

    private let capacity: Int
    private var rowsByKey: [CacheKey: [TranscriptPresentationRow]] = [:]
    private var recency: [CacheKey] = []

    public init(capacity: Int = 24) {
        self.capacity = max(1, capacity)
    }

    public func rows(
        for key: TranscriptProjectionKey,
        input: TranscriptProjectionInput,
        options: TranscriptProjectionOptions
    ) throws -> [TranscriptPresentationRow] {
        let cacheKey = CacheKey(projection: key, options: options)
        if let cached = rowsByKey[cacheKey] {
            touch(cacheKey)
            return cached
        }

        let projected = try Self.project(input, options: options)
        guard !Task.isCancelled else { throw CancellationError() }
        rowsByKey[cacheKey] = projected
        touch(cacheKey)
        while recency.count > capacity {
            rowsByKey.removeValue(forKey: recency.removeFirst())
        }
        return projected
    }

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    public static func project(
        _ input: TranscriptProjectionInput,
        options: TranscriptProjectionOptions
    ) throws -> [TranscriptPresentationRow] {
        var rows: [TranscriptPresentationRow] = []
        rows.reserveCapacity(input.settledConversation.count + 6)
        let settled = input.settledConversation
        let hasSetup = !input.setupPhases.isEmpty
        let pendingMessage = input.pendingUserMessage.flatMap { pending in
            settled.contains(where: { item in
                if case let .user(message) = item { return message.id == pending.id }
                return false
            }) ? nil : pending
        }
        let pendingIsOpeningRow = settled.isEmpty && !input.hasActiveItem
        let waitingDescription = input.waitingBackgroundTaskDescription
        let waitingAssistantID: UUID? = {
            guard !input.hasActiveItem,
                waitingDescription != nil,
                case let .assistant(message)? = settled.last,
                message.turn.finalText != nil
            else { return nil }
            return message.id
        }()

        if settled.isEmpty, !input.hasActiveItem {
            if let message = pendingMessage {
                let showsStartingAgent = !hasSetup
                rows.append(
                    .init(
                        id: .message(message.id),
                        content: .optimistic(message, showsStartingAgent: showsStartingAgent),
                        estimatedHeight: 90,
                        measurementRevision: TranscriptAssistantRowProjection.optimisticMeasurementRevision(
                            for: message,
                            showsStartingAgent: showsStartingAgent
                        )
                    ))
            }
            if hasSetup {
                rows.append(
                    .init(
                        id: .setup,
                        content: .setup(input.setupPhases),
                        estimatedHeight: 80
                    ))
            }
            if !input.isLoadingInitialHistory, pendingMessage == nil {
                if let message = input.serverWaitMessage {
                    rows.append(
                        .init(
                            id: .serverWait,
                            content: .serverWait(message),
                            estimatedHeight: 32
                        ))
                } else if options.includesConnectingRow,
                    case let .connecting(message) = input.status
                {
                    rows.append(
                        .init(
                            id: .connecting,
                            content: .connecting(message),
                            estimatedHeight: 32
                        ))
                }
            }
        }

        for (index, item) in settled.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { throw CancellationError() }
            if index == 0, hasSetup, TranscriptAssistantRowProjection.isAssistant(item) {
                rows.append(
                    .init(
                        id: .setup,
                        content: .setup(input.setupPhases),
                        estimatedHeight: 80
                    ))
            }
            TranscriptAssistantRowProjection.appendSettled(
                item,
                waitingOnBackgroundTask: item.id == waitingAssistantID
                    ? waitingDescription
                    : nil,
                to: &rows
            )
            if index == 0, hasSetup, TranscriptAssistantRowProjection.isUser(item) {
                rows.append(
                    .init(
                        id: .setup,
                        content: .setup(input.setupPhases),
                        estimatedHeight: 80
                    ))
            }
        }

        if settled.isEmpty, input.hasActiveItem, hasSetup {
            rows.append(
                .init(
                    id: .setup,
                    content: .setup(input.setupPhases),
                    estimatedHeight: 80
                ))
        }
        if let activeItem = input.activeItem {
            rows.append(
                .init(
                    id: .active(activeItem.id),
                    content: .active(activeItem),
                    estimatedHeight: 320
                ))
        }
        if !pendingIsOpeningRow, let message = pendingMessage {
            rows.append(
                .init(
                    id: .message(message.id),
                    content: .optimistic(message, showsStartingAgent: false),
                    estimatedHeight: 90,
                    measurementRevision: TranscriptAssistantRowProjection.optimisticMeasurementRevision(
                        for: message,
                        showsStartingAgent: false
                    )
                ))
        }
        if let waitingDescription, waitingAssistantID == nil, !input.hasActiveItem {
            rows.append(
                .init(
                    id: .backgroundTask,
                    content: .backgroundTask(waitingDescription),
                    estimatedHeight: 32
                ))
        }
        if let name = input.waitingHarnessUpdateName {
            rows.append(.init(id: .updateGate, content: .updateGate(name), estimatedHeight: 32))
        }
        if (!settled.isEmpty || input.hasActiveItem), let message = input.serverWaitMessage {
            rows.append(.init(id: .serverWait, content: .serverWait(message), estimatedHeight: 32))
        }
        if let message = input.sessionErrorMessage {
            rows.append(.init(id: .error, content: .error(message), estimatedHeight: 56))
        }
        if case let .failed(message) = input.status,
            message != input.sessionErrorMessage
        {
            rows.append(.init(id: .statusError, content: .error(message), estimatedHeight: 56))
        }
        if let requestedHeight = options.bottomSpacerHeight {
            let height = max(1, requestedHeight)
            rows.append(
                .init(
                    id: .bottomSpacer,
                    content: .bottomSpacer(height),
                    estimatedHeight: height
                ))
        }
        return rows
    }

}
