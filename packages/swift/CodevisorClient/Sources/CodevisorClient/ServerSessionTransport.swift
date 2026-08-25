import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

public struct ServerSessionSnapshot: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var promptQueue: [ServerPromptQueueItem]
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest?
    public var pendingPlanApproval: Bool = false
    public var backgroundTasks: [BackgroundTaskInfo]?
    public var goal: SessionGoal?
}

public struct TranscriptHistoryPage: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var nextBefore: String?
    public var hasMore: Bool
    public var eventCursor: Int
    public var pendingQuestion: QuestionRequest? = nil
    public var pendingPlanApproval: Bool = false
    public var backgroundTasks: [BackgroundTaskInfo]? = nil
    public var goal: SessionGoal? = nil
    public var usage: SessionUsage? = nil
}

public enum SessionTurnInitiator: String, Equatable, Sendable {
    case user
    case agent
}

public enum SessionRuntimeState: String, Equatable, Sendable {
    case running
    case idle
    case requiresAction = "requires_action"
}

public enum ServerSessionStreamEvent: Equatable, Sendable {
    case update(SessionUpdate)
    /// A persisted user message. Carried outside `SessionUpdate` because the
    /// ACP update type cannot carry attachments.
    case userMessage(id: String?, text: String, attachments: [Attachment])
    /// The server-owned identity of the assistant transcript item for a newly
    /// started turn. Live rows adopt this before they settle so their identity
    /// matches snapshots and unread attention targets.
    case assistantItemStarted(UUID)
    /// Server-finalized assistant Markdown plus immutable promoted artifacts.
    case assistantFinalized(markdown: String, messageId: String?, attachments: [Attachment])
    case queueUpdated([ServerPromptQueueItem])
    /// A turn ended. `stopDetail` is a short human-readable reason present only
    /// when the ending was abnormal (error / limit / refusal / gave-up
    /// truncation); the client renders it as a per-turn line. `chatItemId` is
    /// the server-owned identity of the assistant item this turn belongs to —
    /// the same routing the server projection uses — so the closure lands on
    /// that bubble even when it is no longer the active one.
    case finished(
        StopReason,
        stopDetail: String?,
        retryable: Bool = false,
        initiatedBy: SessionTurnInitiator = .user,
        chatItemId: UUID? = nil
    )
    /// A transient failure is being retried; the turn stays alive. Drives the
    /// visible reconnecting status, with progress when the harness provides it.
    case retrying(RetryStatus)
    /// The server is holding this session's prompts while its harness
    /// updates; `waiting: false` releases the marker. Replaceable: the
    /// latest event wins.
    case updateGate(waiting: Bool, harnessName: String)
    case failed(String, retryable: Bool = false, chatItemId: UUID? = nil)
    /// The harness rejected its credentials. Kept distinct from generic
    /// failures so clients can offer the relevant authentication settings.
    case authenticationRequired(String)
    /// Full replace-on-update snapshot of the agent's in-flight background
    /// tasks (backgrounded shells, subagents). Empty means none pending.
    case backgroundTasks([BackgroundTaskInfo])
    /// Claude's main turn-loop state. `idle` is paired with the background-task
    /// snapshot; detached terminal processes do not prevent quiescence.
    case runtimeState(SessionRuntimeState)
    /// Durable form of Codex's synthetic post-plan approval prompt.
    case planApprovalRequired(Bool)
    /// The harness's selected model declined the request and the turn was
    /// re-run on a fallback model. The swap is sticky for the session, so this
    /// is session-level state rather than a per-turn line.
    case modelFallback(SessionModelFallback)
}

/// A refusal-driven model swap reported by the harness: the selected model's
/// safety classifiers declined the request and another model served it.
public struct SessionModelFallback: Sendable, Equatable {
    /// Raw model identifiers as reported by the harness. Display names are
    /// resolved against the live model option, which may no longer list the
    /// original — hence raw values here rather than presentation strings.
    public var originalModel: String
    public var fallbackModel: String
    /// Refusal category (`cyber`, `bio`, …). An open string on the wire: new
    /// categories ship ahead of schema updates, so this is never parsed.
    public var category: String?

    public init(originalModel: String, fallbackModel: String, category: String? = nil) {
        self.originalModel = originalModel
        self.fallbackModel = fallbackModel
        self.category = category
    }
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
}

extension ServerSessionTransport {
    public func prompt(
        _ text: String,
        attachments: [Attachment] = [],
        messageId: String? = nil
    ) async throws -> ServerPromptAccepted {
        try await client.promptSession(
            id: sessionId,
            text: text,
            attachments: attachments.map(\.serverRef),
            messageId: messageId
        )
    }

    public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
        try await client.uploadFile(name: name, mimeType: mimeType, data: data)
    }

    public func fileData(id: String) async throws -> Data {
        try await client.fileData(id: id)
    }

    public func fileData(path: String) async throws -> Data {
        try await client.fileData(sessionId: sessionId, path: path)
    }

    public func updateQueuedPrompt(id: String, text: String) async throws -> ServerPromptQueueItem {
        try await client.updateQueuedPrompt(sessionId: sessionId, queueItemId: id, text: text)
    }

    public func reorderQueuedPrompts(ids: [String]) async throws -> [ServerPromptQueueItem] {
        try await client.reorderQueuedPrompts(sessionId: sessionId, queueItemIds: ids)
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

    public func setConfigOption(
        configId: String,
        value: String
    ) async throws -> [SessionConfigOption]? {
        try await client.setSessionConfigAndReturnOptions(
            id: sessionId,
            configId: configId,
            value: value
        )
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
            pendingPlanApproval: detail.pendingPlanApproval,
            backgroundTasks: detail.backgroundTasks,
            goal: detail.goal
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
        historyPage(from: try await client.transcriptPage(id: sessionId, before: before, limit: limit))
    }

    /// Converts an already-fetched raw page — the combined open call returns
    /// one alongside the session record — into the transport's history
    /// representation without another round-trip.
    public func historyPage(from page: ServerTranscriptPage) -> TranscriptHistoryPage {
        TranscriptHistoryPage(
            // Older/cloud servers can still return completed structural item
            // shells. Filter at the transport boundary so every caller gets a
            // conversation made only of rows that can actually render.
            conversation: page.items
                .map(Self.conversationItem(from:))
                .filter(\.hasRenderableTranscriptContent),
            nextBefore: page.nextBefore,
            hasMore: page.hasMore,
            eventCursor: page.eventCursor,
            pendingQuestion: page.pendingQuestion,
            pendingPlanApproval: page.pendingPlanApproval,
            backgroundTasks: page.backgroundTasks,
            goal: page.goal,
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
        let events =
            envelopes
            .filter { $0.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame }
            .flatMap { Self.sessionStreamEvents(from: $0) }
        return (events, envelopes.last?.id)
    }

    public func streamEvents(
        since: Int = Self.liveOnlyEventCursor
    ) -> AsyncThrowingStream<ServerSessionStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            // The upstream subscription is acquired synchronously at stream
            // construction, NOT inside the bridge task. Callers subscribe and
            // then prompt (`startConsumer()` before `transport.prompt` in
            // SessionModel); if registration happened inside the task it
            // would race that prompt, and for a cursor-less (live-only)
            // session the server replays nothing — events emitted before the
            // subscription registers would be lost permanently.
            let upstream = client.sessionEventStream(id: sessionId, since: since)
            let task = Task {
                do {
                    for try await event in upstream {
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
            // Acquired synchronously for the same reason as `streamEvents`:
            // subscription registration must complete before the caller's
            // next prompt, or live-only streams silently drop its events.
            let upstream = client.eventStream(since: since)
            let task = Task {
                do {
                    for try await event in upstream
                    where
                        event.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame
                    {
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
                conversation.append(
                    .user(
                        UserMessage(
                            id: uuid(from: item.id),
                            text: item.text,
                            attachments: (item.attachments ?? []).map(\.attachment)
                        )))
            case .assistant:
                var assistant =
                    pendingAssistant
                    ?? AssistantMessage(
                        id: uuid(from: item.id),
                        turn: AssistantTurn(isGenerating: item.isGenerating)
                    )
                TranscriptReducer.apply(
                    .agentMessageChunk(.text(item.text), messageId: item.messageId),
                    to: &assistant.turn
                )
                assistant.turn.isGenerating = item.isGenerating
                if let attachments = item.attachments {
                    assistant.turn.attachments = attachments.map(\.attachment)
                }
                pendingAssistant = assistant
            case .system:
                flushAssistant()
            }
        }
        flushAssistant()
        return conversation.filter(\.hasRenderableTranscriptContent)
    }

    private static func conversationItem(from item: ServerTranscriptItem) -> ConversationItem {
        let id = uuid(from: item.id)
        switch item.role {
        case .user:
            return .user(
                UserMessage(
                    id: id,
                    text: item.text,
                    attachments: (item.attachments ?? []).map(\.attachment)
                ))
        case .assistant:
            // A still-streaming item carries the provider message id of its
            // answer candidate. Adopting the live-delta identity (`acp:<id>`)
            // lets TranscriptReducer.appendText merge resumed chunks into
            // this entry instead of appending a second span — which would
            // demote the restored half into "Worked for". Completed items
            // have no live continuation, so the synthetic summary id is fine.
            let textId = item.messageId.map { "acp:\($0)" } ?? "summary:\(item.id)"
            let entries: [TranscriptEntry] = item.text.isEmpty ? [] : [.text(id: textId, markdown: item.text)]
            let turn = AssistantTurn(
                entries: entries,
                attachments: (item.attachments ?? []).map(\.attachment),
                isGenerating: item.isGenerating,
                isThinking: item.isGenerating && item.text.isEmpty,
                stopReason: item.stopReason.flatMap(StopReason.init(rawValue:)),
                stopDetail: item.stopDetail,
                retryable: item.retryable == true,
                planDocument: item.planDocument,
                startedAt: item.startedAt.flatMap(parseServerDate),
                endedAt: item.endedAt.flatMap(parseServerDate),
                textPhases: item.text.isEmpty ? [:] : item.phase.map { [textId: $0] } ?? [:],
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
        if event.payload["sessionUpdate"]?.stringValue == "assistant_message_finalized",
            let markdown = event.payload["markdown"]?.stringValue
        {
            return [
                .assistantFinalized(
                    markdown: markdown,
                    messageId: event.payload["messageId"]?.stringValue,
                    attachments: attachments(from: event.payload)
                )
            ]
        }
        if let rawUpdate = decodeRawSessionUpdate(event.payload) {
            return [.update(rawUpdate)]
        }

        switch event.kind {
        case "session.attention.updated":
            return [
                .planApprovalRequired(
                    event.payload["pendingPlanApproval"]?.boolValue == true
                )
            ]
        case "session.queue.updated":
            return [.queueUpdated(promptQueue(from: event.payload))]
        case "session.updateGate.updated":
            return [
                .updateGate(
                    waiting: event.payload["state"]?.stringValue == "waiting",
                    harnessName: event.payload["harnessName"]?.stringValue
                        ?? event.payload["harnessId"]?.stringValue
                        ?? "the agent"
                )
            ]
        case "session.output":
            return outputEvents(from: event.payload)
        case "session.updated":
            var updates: [ServerSessionStreamEvent] = []
            if event.payload["turnState"]?.stringValue == "started",
                let rawItemId = event.payload["chatItemId"]?.stringValue,
                let itemId = UUID(uuidString: rawItemId)
            {
                updates.append(.assistantItemStarted(itemId))
            }
            if let retry = retryStatus(from: event.payload) {
                return updates + [.retrying(retry)]
            }
            if let stopReason = stopReason(from: event.payload) {
                return updates + [
                    .finished(
                        stopReason,
                        stopDetail: event.payload["stopDetail"]?.stringValue,
                        retryable: event.payload["retryable"]?.boolValue == true,
                        initiatedBy: event.payload["initiatedBy"]?.stringValue
                            .flatMap(SessionTurnInitiator.init(rawValue:)) ?? .user,
                        chatItemId: event.payload["chatItemId"]?.stringValue
                            .flatMap(UUID.init(uuidString:))
                    )
                ]
            }
            if let tasks = backgroundTasks(from: event.payload) {
                return updates + [.backgroundTasks(tasks)]
            }
            if let fallback = modelFallback(from: event.payload) {
                return updates + [.modelFallback(fallback)]
            }
            if let state = event.payload["runtimeState"]?.stringValue
                .flatMap(SessionRuntimeState.init(rawValue:))
            {
                return updates + [.runtimeState(state)]
            }
            return updates
                + metadataUpdates(from: event.payload).map(ServerSessionStreamEvent.update)
        case "session.error":
            return [
                .failed(
                    errorMessage(from: event.payload),
                    retryable: event.payload["retryable"]?.boolValue == true,
                    chatItemId: event.payload["chatItemId"]?.stringValue
                        .flatMap(UUID.init(uuidString:))
                )
            ]
        case "session.authRequired":
            return [
                .authenticationRequired(
                    event.payload["detail"]?.stringValue
                        ?? "Sign-in expired. Sign in again in Harness Settings to continue."
                )
            ]
        default:
            return []
        }
    }

    /// Shared coders for the `JSONValue` → typed-model bridge below. These
    /// run per streamed event — one per token chunk on the hot path — and a
    /// fresh `JSONEncoder`/`JSONDecoder` allocation per call is measurable
    /// under several concurrent streams. Sharing is safe: both types create
    /// all mutable state per `encode`/`decode` call.
    private static let bridgeEncoder = JSONEncoder()
    private static let bridgeDecoder = JSONDecoder()

    private static func promptQueue(from payload: JSONValue) -> [ServerPromptQueueItem] {
        guard let queue = payload["queue"]?.arrayValue else { return [] }
        do {
            let data = try bridgeEncoder.encode(JSONValue.array(queue))
            return try bridgeDecoder.decode([ServerPromptQueueItem].self, from: data)
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
            let data = try bridgeEncoder.encode(payload)
            return try bridgeDecoder.decode(SessionUpdate.self, from: data)
        } catch {
            Log.session.error(
                "Failed to decode session-update payload: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    private static func outputEvents(from payload: JSONValue) -> [ServerSessionStreamEvent] {
        guard let role = payload["role"]?.stringValue,
            let text = payload["text"]?.stringValue
        else {
            return []
        }
        switch role {
        case "assistant" where !text.isEmpty:
            return [.update(.agentMessageChunk(.text(text), messageId: payload["messageId"]?.stringValue))]
        case "user":
            let attachments = attachments(from: payload)
            guard !text.isEmpty || !attachments.isEmpty else { return [] }
            return [
                .userMessage(
                    id: payload["messageId"]?.stringValue,
                    text: text,
                    attachments: attachments
                )
            ]
        default:
            return []
        }
    }

    private static func attachments(from payload: JSONValue) -> [Attachment] {
        guard let raw = payload["attachments"]?.arrayValue else { return [] }
        do {
            let data = try bridgeEncoder.encode(JSONValue.array(raw))
            return try bridgeDecoder.decode([ServerAttachmentRef].self, from: data).map(\.attachment)
        } catch {
            Log.session.error(
                "Failed to decode attachments payload: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    /// Both model ids are required: a notice that cannot name what was swapped
    /// for what is not worth showing, so a malformed payload is skipped.
    private static func modelFallback(from payload: JSONValue) -> SessionModelFallback? {
        guard let value = payload["modelFallback"],
            let originalModel = value["originalModel"]?.stringValue,
            let fallbackModel = value["fallbackModel"]?.stringValue
        else { return nil }
        return SessionModelFallback(
            originalModel: originalModel,
            fallbackModel: fallbackModel,
            category: value["category"]?.stringValue
        )
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
            let data = try bridgeEncoder.encode(value)
            return try bridgeDecoder.decode(SessionGoal.self, from: data)
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
            let data = try bridgeEncoder.encode(JSONValue.array(raw))
            return try bridgeDecoder.decode([BackgroundTaskInfo].self, from: data)
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
            let data = try bridgeEncoder.encode(value)
            return try bridgeDecoder.decode([SessionConfigOption].self, from: data)
        } catch {
            Log.session.error(
                "Failed to decode config-options payload: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}
