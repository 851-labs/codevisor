import Foundation
import ACPKit

public struct ServerSessionSnapshot: Equatable, Sendable {
    public var conversation: [ConversationItem]
    public var promptQueue: [ServerPromptQueueItem]
    public var eventCursor: Int
}

public enum ServerSessionStreamEvent: Equatable, Sendable {
    case update(SessionUpdate)
    /// A persisted user message. Carried outside `SessionUpdate` because the
    /// ACP update type cannot carry attachments.
    case userMessage(text: String, attachments: [Attachment])
    case queueUpdated([ServerPromptQueueItem])
    case finished(StopReason)
    case failed(String)
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

    public init(id: String, description: String, status: String, taskType: String, toolUseId: String? = nil) {
        self.id = id
        self.description = description
        self.status = status
        self.taskType = taskType
        self.toolUseId = toolUseId
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

    private let client: any HerdManServerClienting
    private let sessionId: UUID

    public init(client: any HerdManServerClienting, sessionId: UUID) {
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
            eventCursor: detail.eventCursor
        )
    }

    public func updates(since: Int = Self.liveOnlyEventCursor) -> AsyncStream<SessionUpdate> {
        AsyncStream { continuation in
            let task = Task {
                for await streamEvent in streamEvents(since: since) {
                    guard case let .update(update) = streamEvent else { continue }
                    continuation.yield(update)
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

    public func streamEvents(since: Int = Self.liveOnlyEventCursor) -> AsyncStream<ServerSessionStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await event in client.eventStream(since: since) {
                        guard event.subjectId.caseInsensitiveCompare(sessionId.uuidString) == .orderedSame else {
                            continue
                        }
                        for update in Self.sessionStreamEvents(from: event) {
                            continuation.yield(update)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
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
            if let stopReason = stopReason(from: event.payload) {
                return [.finished(stopReason)]
            }
            if let tasks = backgroundTasks(from: event.payload) {
                return [.backgroundTasks(tasks)]
            }
            return metadataUpdates(from: event.payload).map(ServerSessionStreamEvent.update)
        case "session.error":
            return [.failed(errorMessage(from: event.payload))]
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
            return []
        }
    }

    private static func decodeRawSessionUpdate(_ payload: JSONValue) -> SessionUpdate? {
        guard payload["sessionUpdate"] != nil else { return nil }
        do {
            let data = try JSONEncoder().encode(payload)
            return try JSONDecoder().decode(SessionUpdate.self, from: data)
        } catch {
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
            return nil
        }
    }

    private static func stopReason(from payload: JSONValue) -> StopReason? {
        guard let raw = payload["stopReason"]?.stringValue else { return nil }
        return StopReason(rawValue: raw)
    }

    private static func backgroundTasks(from payload: JSONValue) -> [BackgroundTaskInfo]? {
        guard let raw = payload["backgroundTasks"]?.arrayValue else { return nil }
        do {
            let data = try JSONEncoder().encode(JSONValue.array(raw))
            return try JSONDecoder().decode([BackgroundTaskInfo].self, from: data)
        } catch {
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
            return nil
        }
    }
}
