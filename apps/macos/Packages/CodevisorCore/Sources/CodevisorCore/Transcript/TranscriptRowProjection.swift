import CoreGraphics
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
    public let hasActiveItem: Bool
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
        hasActiveItem: Bool,
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
        self.hasActiveItem = hasActiveItem
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

        public var layoutKey: String {
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

        public var isCacheableSettledRow: Bool {
            switch self {
            case .message, .assistantPlanning, .plan, .assistantResult: true
            case .active, .setup, .backgroundTask, .updateGate, .connecting,
                 .serverWait, .error, .statusError, .bottomSpacer: false
            }
        }

        public var isPlanDocument: Bool {
            if case .plan = self { true } else { false }
        }
    }

    public enum Content: Equatable, Sendable {
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

    public let id: ID
    public let content: Content
    public let estimatedHeight: CGFloat
    public let measurementRevision: Int
    public let layoutKey: String

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
        measurementRevision: Int = 0
    ) {
        self.id = id
        self.content = content
        self.estimatedHeight = estimatedHeight
        self.measurementRevision = measurementRevision
        layoutKey = id.layoutKey
    }
}

/// Serializes and caches transcript projection away from the UI actor. A
/// cache hit makes revisiting a chat O(1); cancellation checks stop a rapid
/// sequence of sidebar taps from finishing obsolete transcript work.
public actor TranscriptRowProjectionCache {
    public static let shared = TranscriptRowProjectionCache()

    private struct CacheKey: Hashable {
        let projection: TranscriptProjectionKey
        let options: TranscriptProjectionOptions
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
                  message.turn.finalText != nil else { return nil }
            return message.id
        }()

        if settled.isEmpty, !input.hasActiveItem {
            if let message = pendingMessage {
                let showsStartingAgent = !hasSetup
                rows.append(.init(
                    id: .message(message.id),
                    content: .optimistic(message, showsStartingAgent: showsStartingAgent),
                    estimatedHeight: 90,
                    measurementRevision: optimisticMeasurementRevision(
                        for: message,
                        showsStartingAgent: showsStartingAgent
                    )
                ))
            }
            if hasSetup {
                rows.append(.init(
                    id: .setup,
                    content: .setup(input.setupPhases),
                    estimatedHeight: 80
                ))
            }
            if !input.isLoadingInitialHistory, pendingMessage == nil {
                if let message = input.serverWaitMessage {
                    rows.append(.init(
                        id: .serverWait,
                        content: .serverWait(message),
                        estimatedHeight: 32
                    ))
                } else if options.includesConnectingRow,
                          case let .connecting(message) = input.status {
                    rows.append(.init(
                        id: .connecting,
                        content: .connecting(message),
                        estimatedHeight: 32
                    ))
                }
            }
        }

        for (index, item) in settled.enumerated() {
            if index.isMultiple(of: 32), Task.isCancelled { throw CancellationError() }
            if index == 0, hasSetup, isAssistant(item) {
                rows.append(.init(
                    id: .setup,
                    content: .setup(input.setupPhases),
                    estimatedHeight: 80
                ))
            }
            appendSettled(
                item,
                waitingOnBackgroundTask: item.id == waitingAssistantID
                    ? waitingDescription
                    : nil,
                to: &rows
            )
            if index == 0, hasSetup, isUser(item) {
                rows.append(.init(
                    id: .setup,
                    content: .setup(input.setupPhases),
                    estimatedHeight: 80
                ))
            }
        }

        if settled.isEmpty, input.hasActiveItem, hasSetup {
            rows.append(.init(
                id: .setup,
                content: .setup(input.setupPhases),
                estimatedHeight: 80
            ))
        }
        if input.hasActiveItem {
            rows.append(.init(id: .active, content: .active, estimatedHeight: 320))
        }
        if !pendingIsOpeningRow, let message = pendingMessage {
            rows.append(.init(
                id: .message(message.id),
                content: .optimistic(message, showsStartingAgent: false),
                estimatedHeight: 90,
                measurementRevision: optimisticMeasurementRevision(
                    for: message,
                    showsStartingAgent: false
                )
            ))
        }
        if let waitingDescription, waitingAssistantID == nil, !input.hasActiveItem {
            rows.append(.init(
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
           message != input.sessionErrorMessage {
            rows.append(.init(id: .statusError, content: .error(message), estimatedHeight: 56))
        }
        if let requestedHeight = options.bottomSpacerHeight {
            let height = max(1, requestedHeight)
            rows.append(.init(
                id: .bottomSpacer,
                content: .bottomSpacer(height),
                estimatedHeight: height
            ))
        }
        return rows
    }

    private static func appendSettled(
        _ item: ConversationItem,
        waitingOnBackgroundTask: String?,
        to rows: inout [TranscriptPresentationRow]
    ) {
        guard case let .assistant(message) = item,
              let planDocument = message.turn.planDocument,
              !planDocument.isEmpty else {
            rows.append(.init(
                id: .message(item.id),
                content: .message(item, waitingOnBackgroundTask: waitingOnBackgroundTask),
                estimatedHeight: estimatedHeight(for: item),
                measurementRevision: measurementRevision(
                    for: item,
                    waitingOnBackgroundTask: waitingOnBackgroundTask
                )
            ))
            return
        }

        let revision = measurementRevision(
            for: item,
            waitingOnBackgroundTask: waitingOnBackgroundTask
        )
        if message.turn.hasDeferredWorkedDetails || !message.turn.workedItemsBeforePlan.isEmpty {
            rows.append(.init(
                id: .assistantPlanning(message.id),
                content: .assistantPlanning(message),
                estimatedHeight: 44,
                measurementRevision: revision
            ))
        }
        rows.append(.init(
            id: .plan(message.id),
            content: .planDocument(planDocument),
            estimatedHeight: estimatedPlanHeight(planDocument),
            measurementRevision: planMeasurementRevision(planDocument)
        ))
        if !message.turn.workedItemsAfterPlan.isEmpty
            || message.turn.finalText != nil
            || message.turn.stopDetail != nil
            || message.turn.isGenerating {
            rows.append(.init(
                id: .assistantResult(message.id),
                content: .assistantResult(
                    message,
                    waitingOnBackgroundTask: waitingOnBackgroundTask
                ),
                estimatedHeight: 240,
                measurementRevision: revision
            ))
        }
    }

    private static func isUser(_ item: ConversationItem) -> Bool {
        if case .user = item { return true }
        return false
    }

    private static func isAssistant(_ item: ConversationItem) -> Bool {
        if case .assistant = item { return true }
        return false
    }

    private static func estimatedHeight(for item: ConversationItem) -> CGFloat {
        switch item {
        case let .user(message):
            max(52, min(240, 48 + CGFloat(message.text.count / 72) * 18))
        case .assistant:
            320
        }
    }

    private static func estimatedPlanHeight(_ markdown: String) -> CGFloat {
        max(120, min(640, 72 + CGFloat(markdown.utf8.count / 72) * 18))
    }

    private static func planMeasurementRevision(_ markdown: String) -> Int {
        var hasher = Hasher()
        hasher.combine(markdown.utf8.count)
        return hasher.finalize()
    }

    private static func optimisticMeasurementRevision(
        for message: UserMessage,
        showsStartingAgent: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(2)
        hasher.combine(message.text.utf8.count)
        hasher.combine(message.attachments.count)
        for attachment in message.attachments {
            hasher.combine(attachment.id)
            hasher.combine(attachment.sizeBytes)
        }
        hasher.combine(showsStartingAgent)
        return hasher.finalize()
    }

    private static func measurementRevision(
        for item: ConversationItem,
        waitingOnBackgroundTask: String?
    ) -> Int {
        var hasher = Hasher()
        switch item {
        case let .user(message):
            hasher.combine(0)
            hasher.combine(message.text.utf8.count)
            hasher.combine(message.attachments.count)
            for attachment in message.attachments {
                hasher.combine(attachment.id)
                hasher.combine(attachment.sizeBytes)
            }
        case let .assistant(message):
            let turn = message.turn
            hasher.combine(1)
            hasher.combine(turn.entries.count)
            hasher.combine(turn.isGenerating)
            hasher.combine(turn.detailRevision)
            hasher.combine(turn.hasDeferredWorkedDetails)
            hasher.combine(turn.contextCompactionStatus?.rawValue)
            hasher.combine(turn.planDocument?.utf8.count ?? 0)
            hasher.combine(turn.stopDetail?.utf8.count ?? 0)
            hasher.combine(turn.subagentActivityFingerprint)
            hasher.combine(turn.attachments.count)
            for attachment in turn.attachments {
                hasher.combine(attachment.id)
                hasher.combine(attachment.sizeBytes)
            }
        }
        hasher.combine(waitingOnBackgroundTask)
        return hasher.finalize()
    }
}
