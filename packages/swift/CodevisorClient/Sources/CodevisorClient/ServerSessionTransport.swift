import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

public struct ServerSessionTransport: Sendable {
    public static let liveOnlyEventCursor = 9_007_199_254_740_991

    let client: any CodevisorServerClienting
    let sessionId: UUID

    public init(client: any CodevisorServerClienting, sessionId: UUID) {
        self.client = client
        self.sessionId = sessionId
    }
}

extension ServerSessionTransport {
    public func snapshot() async throws -> ServerSessionSnapshot {
        let detail = try await client.sessionDetail(id: sessionId)
        return ServerSessionSnapshot(
            conversation: Self.conversationItems(from: detail.conversation),
            promptQueue: detail.promptQueue,
            eventCursor: detail.eventCursor,
            pendingQuestion: detail.pendingQuestion,
            pendingPlanApproval: detail.pendingPlanApproval,
            backgroundTasks: detail.backgroundTasks,
            goal: detail.goal,
            sessionPlan: detail.sessionPlan
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
            sessionPlan: page.sessionPlan,
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
                stopKind: item.stopKind,
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
                        stopKind: event.payload["stopKind"]?.stringValue,
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
