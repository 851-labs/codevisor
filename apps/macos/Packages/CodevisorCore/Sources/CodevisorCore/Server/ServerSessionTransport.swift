import Foundation
import ACPKit

public struct ServerSessionSnapshot: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var promptQueue: [ServerPromptQueueItem]
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest?
    public var backgroundTasks: [BackgroundTaskInfo]?
}

public struct TranscriptHistoryPage: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var nextBefore: String?
    public var hasMore: Bool
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest? = nil
    public var backgroundTasks: [BackgroundTaskInfo]? = nil
    public var usage: SessionUsage? = nil
}

public enum ServerSessionStreamEvent: Equatable, Sendable {
    case update(SessionUpdate)
    /// A persisted user message. Carried outside `SessionUpdate` because the
    /// ACP update type cannot carry attachments.
    case userMessage(text: String, attachments: [Attachment])
    case queueUpdated([ServerPromptQueueItem])
    /// A turn ended. `stopDetail` is a short human-readable reason present only
    /// when the ending was abnormal (error / limit / refusal / gave-up
    /// truncation); the client renders it as a per-turn line.
    case finished(StopReason, stopDetail: String?, retryable: Bool = false)
    /// A transient failure is being retried; the turn stays alive. Drives the
    /// visible reconnecting status, with progress when the harness provides it.
    case retrying(RetryStatus)
    case failed(String)
    /// The harness rejected its credentials. Kept distinct from generic
    /// failures so clients can offer the relevant authentication settings.
    case authenticationRequired(String)
    /// Full replace-on-update snapshot of the agent's in-flight background
    /// tasks (backgrounded shells, subagents). Empty means none pending.
    case backgroundTasks([BackgroundTaskInfo])
}

/// One in-flight background task owned by the agent process, from the
/// `session.updated` `backgroundTasks` snapshot payload.
public struct BackgroundTaskInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var description: String
    public var status: String
    public var taskType: String
    public var toolUseId: String?
    /// Set when the task's process streams through a server-owned terminal.
    /// Clients attach with the regular terminal API (`sessionId: terminalKey`,
    /// `attachOnly: true`) and render the task as a live terminal tab instead
    /// of the "Waiting on…" indicator.
    public var terminalKey: String?
    /// The terminal is a read-only mirror: input and kill are unavailable
    /// while the task runs (codex owns its command executions).
    public var readOnly: Bool?

    public init(
        id: String,
        description: String,
        status: String,
        taskType: String,
        toolUseId: String? = nil,
        terminalKey: String? = nil,
        readOnly: Bool? = nil
    ) {
        self.id = id
        self.description = description
        self.status = status
        self.taskType = taskType
        self.toolUseId = toolUseId
        self.terminalKey = terminalKey
        self.readOnly = readOnly
    }
}

public extension ServerAttachmentRef {
    var attachment: Attachment {
        Attachment(
            fileId: fileId,
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            kind: kind == .image ? .image : .file
        )
    }
}

public extension Attachment {
    var serverRef: ServerAttachmentRef {
        ServerAttachmentRef(
            fileId: fileId,
            name: name,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            kind: kind == .image ? .image : .file
        )
    }
}

public struct ServerSessionTransport: Sendable {
    public static let liveOnlyEventCursor = 9_007_199_254_740_991

    private let client: any CodevisorServerClienting
    private let sessionId: UUID

    public init(client: any CodevisorServerClienting, sessionId: UUID) {
        self.client = client
        self.sessionId = sessionId
    }

    public func prompt(_ text: String, attachments: [Attachment] = []) async throws -> ServerPromptAccepted {
        try await client.promptSession(id: sessionId, text: text, attachments: attachments.map(\.serverRef))
    }

    public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
        try await client.uploadFile(name: name, mimeType: mimeType, data: data)
    }

    public func fileData(id: String) async throws -> Data {
        try await client.fileData(id: id)
    }

    public func updateQueuedPrompt(id: String, text: String) async throws -> ServerPromptQueueItem {
        try await client.updateQueuedPrompt(sessionId: sessionId, queueItemId: id, text: text)
    }

    public func deleteQueuedPrompt(id: String) async throws {
        try await client.deleteQueuedPrompt(sessionId: sessionId, queueItemId: id)
    }

    public func cancel() async throws {
        try await client.cancelSession(id: sessionId)
    }

    public func setMode(_ modeId: String) async throws {
        try await client.setSessionMode(id: sessionId, modeId: modeId)
    }

    public func setConfigOption(configId: String, value: String) async throws {
        try await client.setSessionConfig(id: sessionId, configId: configId, value: value)
    }

    @discardableResult
    public func setGoal(
        objective: String? = nil,
        status: GoalStatus? = nil,
        tokenBudget: TokenBudgetUpdate = .keep
    ) async throws -> SessionGoal {
        try await client.setSessionGoal(
            id: sessionId,
            objective: objective,
            status: status,
            tokenBudget: tokenBudget
        )
    }

    public func clearGoal() async throws {
        try await client.clearSessionGoal(id: sessionId)
    }

    public func answerQuestion(
        id questionId: String,
        outcome: String,
        answers: [String: QuestionAnswerEntry]?
    ) async throws {
        try await client.answerSessionQuestion(
            id: sessionId,
            questionId: questionId,
            outcome: outcome,
            answers: answers
        )
    }

    public func snapshot() async throws -> ServerSessionSnapshot {
        let detail = try await client.sessionDetail(id: sessionId)
        return ServerSessionSnapshot(
            conversation: Self.conversationItems(from: detail.conversation),
            promptQueue: detail.promptQueue,
            eventCursor: detail.eventCursor,
            pendingQuestion: detail.pendingQuestion,
            backgroundTasks: detail.backgroundTasks
        )
    }

    public func usageLimits() async throws -> ServerHarnessUsageLimits {
        try await client.sessionUsageLimits(id: sessionId)
    }

    public func promptQueue() async throws -> [ServerPromptQueueItem] {
        try await client.promptQueue(id: sessionId)
    }

    /// Lightweight reverse-paginated history. Historical worked details are
    /// represented by a deferred item id and fetched only on expansion.
    public func transcriptPage(before: String? = nil, limit: Int = 32) async throws -> TranscriptHistoryPage {
        let page = try await client.transcriptPage(id: sessionId, before: before, limit: limit)
        return TranscriptHistoryPage(
            conversation: page.items.map(Self.conversationItem(from:)),
            nextBefore: page.nextBefore,
            hasMore: page.hasMore,
            eventCursor: page.eventCursor,
            pendingQuestion: page.pendingQuestion,
            backgroundTasks: page.backgroundTasks,
            usage: page.usage?.sessionUsage
        )
    }

    public func transcriptDetails(itemId: String) async throws -> [ServerSessionStreamEvent] {
        let details = try await client.transcriptItemDetails(id: sessionId, itemId: itemId)
        return details.events.flatMap(Self.sessionStreamEvents(from:))
    }

    public func updates(since: Int = Self.liveOnlyEventCursor) -> AsyncStream<SessionUpdate> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await streamEvent in streamEvents(since: since) {
                        guard case let .update(update) = streamEvent else { continue }
                        continuation.yield(update)
                    }
                } catch {
                    // This compatibility wrapper cannot surface failures;
                    // SessionModel consumes streamEvents directly and
                    // performs durable reconciliation.
                    Log.session.debug(
                        "Legacy updates() stream ended with error: \(String(describing: error), privacy: .public)"
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The session's full persisted event history, mapped to the same stream
    /// events the live pipeline applies — replaying them rebuilds the rich
    /// transcript (tool calls, diffs, turn boundaries). Returns the id of the
    /// last envelope so live streaming can resume exactly after it.
    public func history() async throws -> (events: [ServerSessionStreamEvent], cursor: Int?) {
        let envelopes = try await client.sessionEvents(id: sessionId)
        let events = envelopes
            .filter { $0.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame }
            .flatMap { Self.sessionStreamEvents(from: $0) }
        return (events, envelopes.last?.id)
    }

    public func streamEvents(
        since: Int = Self.liveOnlyEventCursor
    ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in client.sessionEventStream(id: sessionId, since: since) {
                        for update in Self.sessionStreamEvents(from: event) {
                            continuation.yield(update)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compatibility path for servers that predate the canonical transcript
    /// endpoint and therefore also lack the session-scoped WebSocket.
    public func legacyStreamEvents(
        since: Int
    ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in client.eventStream(since: since) where
                        event.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame {
                        for update in Self.sessionStreamEvents(from: event) {
                            continuation.yield(update)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func conversationItems(from items: [ServerConversationItem]) -> [ConversationItem] {
        var conversation: [ConversationItem] = []
        var pendingAssistant: AssistantMessage?

        func flushAssistant() {
            if let assistant = pendingAssistant {
                conversation.append(.assistant(assistant))
                pendingAssistant = nil
            }
        }

        for item in items {
            switch item.role {
            case .user:
                flushAssistant()
                conversation.append(.user(UserMessage(
                    id: uuid(from: item.id),
                    text: item.text,
                    attachments: (item.attachments ?? []).map(\.attachment)
                )))
            case .assistant:
                var assistant = pendingAssistant ?? AssistantMessage(
                    id: uuid(from: item.id),
                    turn: AssistantTurn(isGenerating: item.isGenerating)
                )
                TranscriptReducer.apply(
                    .agentMessageChunk(.text(item.text), messageId: item.messageId),
                    to: &assistant.turn
                )
                assistant.turn.isGenerating = item.isGenerating
                pendingAssistant = assistant
            case .system:
                flushAssistant()
            }
        }
        flushAssistant()
        return conversation
    }

    private static func conversationItem(from item: ServerTranscriptItem) -> ConversationItem {
        let id = uuid(from: item.id)
        switch item.role {
        case .user:
            return .user(UserMessage(
                id: id,
                text: item.text,
                attachments: (item.attachments ?? []).map(\.attachment)
            ))
        case .assistant:
            let textId = "summary:\(item.id)"
            let entries: [TranscriptEntry] = item.text.isEmpty ? [] : [.text(id: textId, markdown: item.text)]
            let turn = AssistantTurn(
                entries: entries,
                isGenerating: item.isGenerating,
                isThinking: item.isGenerating && item.text.isEmpty,
                stopReason: item.stopReason.flatMap(StopReason.init(rawValue:)),
                stopDetail: item.stopDetail,
                retryable: item.retryable == true,
                planDocument: item.planDocument,
                startedAt: item.startedAt.flatMap(parseServerDate),
                endedAt: item.endedAt.flatMap(parseServerDate),
                textPhases: item.text.isEmpty ? [:] : [textId: .final],
                deferredDetailItemId: item.hasDetails ? item.id : nil,
                hasDeferredWorkedDetails: item.hasDetails,
                detailRevision: item.revision
            )
            return .assistant(AssistantMessage(id: id, turn: turn))
        }
    }

    private static func parseServerDate(_ value: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
    }

    private static func uuid(from id: String) -> UUID {
        UUID(uuidString: id) ?? UUID()
    }

    private static func sessionStreamEvents(from event: ServerEventEnvelope) -> [ServerSessionStreamEvent] {
        if let rawUpdate = decodeRawSessionUpdate(event.payload) {
            return [.update(rawUpdate)]
        }

        switch event.kind {
        case "session.queue.updated":
            return [.queueUpdated(promptQueue(from: event.payload))]
        case "session.output":
            return outputEvents(from: event.payload)
        case "session.updated":
            if let retry = retryStatus(from: event.payload) {
                return [.retrying(retry)]
            }
            if let stopReason = stopReason(from: event.payload) {
                return [.finished(
                    stopReason,
                    stopDetail: event.payload["stopDetail"]?.stringValue,
                    retryable: event.payload["retryable"]?.boolValue == true
                )]
            }
            if let tasks = backgroundTasks(from: event.payload) {
                return [.backgroundTasks(tasks)]
            }
            return metadataUpdates(from: event.payload).map(ServerSessionStreamEvent.update)
        case "session.error":
            return [.failed(errorMessage(from: event.payload))]
        case "session.authRequired":
            return [.authenticationRequired(
                event.payload["detail"]?.stringValue
                    ?? "Sign-in expired. Sign in again in Harness Settings to continue."
            )]
        default:
            return []
        }
    }

    private static func promptQueue(from payload: JSONValue) -> [ServerPromptQueueItem] {
        guard let queue = payload["queue"]?.arrayValue else { return [] }
        do {
            let data = try JSONEncoder().encode(JSONValue.array(queue))
            return try JSONDecoder().decode([ServerPromptQueueItem].self, from: data)
        } catch {
            Log.session.error(
                "Failed to decode prompt-queue payload: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private static func decodeRawSessionUpdate(_ payload: JSONValue) -> SessionUpdate? {
        guard payload["sessionUpdate"] != nil else { return nil }
        do {
            let data = try JSONEncoder().encode(payload)
            return try JSONDecoder().decode(SessionUpdate.self, from: data)
        } catch {
            Log.session.error(
                "Failed to decode session-update payload: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private static func outputEvents(from payload: JSONValue) -> [ServerSessionStreamEvent] {
        guard let role = payload["role"]?.stringValue,
              let text = payload["text"]?.stringValue else {
            return []
        }
        switch role {
        case "assistant" where !text.isEmpty:
            return [.update(.agentMessageChunk(.text(text), messageId: payload["messageId"]?.stringValue))]
        case "user":
            let attachments = attachments(from: payload)
            guard !text.isEmpty || !attachments.isEmpty else { return [] }
            return [.userMessage(text: text, attachments: attachments)]
        default:
            return []
        }
    }

    private static func attachments(from payload: JSONValue) -> [Attachment] {
        guard let raw = payload["attachments"]?.arrayValue else { return [] }
        do {
            let data = try JSONEncoder().encode(JSONValue.array(raw))
            return try JSONDecoder().decode([ServerAttachmentRef].self, from: data).map(\.attachment)
        } catch {
            Log.session.error(
                "Failed to decode attachments payload: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private static func metadataUpdates(from payload: JSONValue) -> [SessionUpdate] {
        if let configOptions = decodeConfigOptions(payload["configOptions"]) {
            return [.configOptionUpdate(configOptions)]
        }
        if let modeId = payload["modeId"]?.stringValue {
            return [.currentModeUpdate(currentModeId: modeId)]
        }
        if let goal = decodeGoal(payload["goal"]) {
            return [.goalUpdate(goal)]
        }
        if payload["goalCleared"]?.boolValue == true {
            return [.goalCleared]
        }
        return []
    }

    private static func decodeGoal(_ value: JSONValue?) -> SessionGoal? {
        guard let value else { return nil }
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(SessionGoal.self, from: data)
        } catch {
            // Lenient like the other decoders: an unknown status or malformed
            // snapshot degrades to skipping the update.
            Log.session.error(
                "Failed to decode goal payload: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private static func stopReason(from payload: JSONValue) -> StopReason? {
        guard let raw = payload["stopReason"]?.stringValue else { return nil }
        return StopReason(rawValue: raw)
    }

    private static func retryStatus(from payload: JSONValue) -> RetryStatus? {
        guard let retry = payload["retrying"] else { return nil }
        return RetryStatus(
            attempt: retry["attempt"]?.intValue,
            of: retry["of"]?.intValue,
            message: retry["message"]?.stringValue ?? "Server is busy, reconnecting"
        )
    }

    private static func backgroundTasks(from payload: JSONValue) -> [BackgroundTaskInfo]? {
        guard let raw = payload["backgroundTasks"]?.arrayValue else { return nil }
        do {
            let data = try JSONEncoder().encode(JSONValue.array(raw))
            return try JSONDecoder().decode([BackgroundTaskInfo].self, from: data)
        } catch {
            Log.session.error(
                "Failed to decode background-tasks payload: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private static func errorMessage(from payload: JSONValue) -> String {
        payload["message"]?.stringValue ?? "The server reported an error."
    }

    private static func decodeConfigOptions(_ value: JSONValue?) -> [SessionConfigOption]? {
        guard let value else { return nil }
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode([SessionConfigOption].self, from: data)
        } catch {
            Log.session.error(
                "Failed to decode config-options payload: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}
