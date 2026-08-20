import Foundation
import Testing
import ACPKit

@testable import CodevisorCore

extension SessionModelTests {
    func model(
        _ client: FakeSessionServerClient,
        sessionId: UUID,
        _ body: (SessionModel) async -> Void
    ) async {
        let model = SessionModel(
            serverTransport: ServerSessionTransport(client: client, sessionId: sessionId),
            sessionId: sessionId.uuidString
        )
        await body(model)
    }

    func settleUntil(
        timeout: Duration = .seconds(5),
        _ predicate: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            // A real delay gives the main-actor event consumer a fair chance
            // to run even when the full Swift suite starts hundreds of tests
            // concurrently. Counting bare yields made the effective timeout
            // depend on runner load and could expire before one actor turn.
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard !predicate() else { return }
        Issue.record("Timed out waiting for SessionModel to settle")
    }

    func userMessages(_ model: SessionModel) -> [UserMessage] {
        model.conversation.compactMap { item in
            if case let .user(message) = item { return message }
            return nil
        }
    }

    func toolCallEnvelope(id: Int, sessionId: UUID, toolCallId: String, status: String) -> ServerEventEnvelope {
        ServerEventEnvelope(
            id: id,
            serverId: "local",
            kind: "session.output",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:00.000Z",
            payload: .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string(toolCallId),
                "title": .string("Edited file"),
                "kind": .string("edit"),
                "status": .string(status),
            ])
        )
    }

    func stopEnvelope(id: Int, sessionId: UUID, stopReason: String) -> ServerEventEnvelope {
        ServerEventEnvelope(
            id: id,
            serverId: "local",
            kind: "session.updated",
            subjectId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:01.000Z",
            payload: .object(["stopReason": .string(stopReason)])
        )
    }

    func cancellationTranscriptPage(
        sessionId: UUID,
        isGenerating: Bool,
        stopReason: String?,
        eventCursor: Int = 2,
        text: String = ""
    ) -> ServerTranscriptPage {
        ServerTranscriptPage(
            items: [
                ServerTranscriptItem(
                    id: UUID().uuidString,
                    sessionId: sessionId.uuidString,
                    sequence: 1,
                    role: .assistant,
                    text: text,
                    createdAt: "2026-07-29T00:00:00.000Z",
                    updatedAt: "2026-07-29T00:00:01.000Z",
                    isGenerating: isGenerating,
                    hasDetails: false,
                    turnId: "cancel-turn",
                    startedAt: "2026-07-29T00:00:00.000Z",
                    endedAt: isGenerating ? nil : "2026-07-29T00:00:01.000Z",
                    stopReason: stopReason,
                    stopDetail: nil,
                    planDocument: nil,
                    attachments: nil,
                    revision: 2
                )
            ],
            hasMore: false,
            eventCursor: eventCursor
        )
    }

    /// Waits until the model's last assistant turn satisfies the predicate,
    /// so emitted stream events land before assertions run.
    func settleAssistant(_ model: SessionModel, until predicate: (AssistantMessage) -> Bool) async {
        await settleUntil {
            guard case let .assistant(assistant) = model.conversation.last else {
                return false
            }
            return predicate(assistant)
        }
    }
}

/// A clock that returns scripted timestamps in order, repeating the last value.
final class TimeBox: @unchecked Sendable {
    private let values: [Date]
    private var index = 0
    private let lock = NSLock()
    init(values: [Date]) { self.values = values }
    func next() -> Date {
        lock.withLock {
            let value = values[min(index, values.count - 1)]
            index += 1
            return value
        }
    }
}

final class FakeSessionServerClient: CodevisorServerClienting, @unchecked Sendable {
    private let sessionId: UUID
    private let projectId = UUID()
    // Multi-subscription event plumbing: each `sessionEventStream` /
    // `eventStream` call gets its own stream, seeded with every event emitted
    // so far — mirroring the real server's replay-from-history semantics.
    // First subscriptions behave exactly as the old single shared stream did
    // (pre-subscription emits are buffered); re-subscriptions after a
    // reconcile keep receiving live events instead of a dead stream.
    private var _eventBuffer: [ServerEventEnvelope] = []
    private var _eventContinuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
    private let lock = NSLock()

    private var _promptedTexts: [String] = []
    private var _promptedAttachments: [[ServerAttachmentRef]] = []
    private var _promptedMessageIds: [String?] = []
    private var _promptGate: AsyncStream<Void>?
    private var _cancelCount = 0
    private var _configUpdates: [(String, String)] = []
    private var _configUpdateGate: AsyncStream<Void>?
    private var _nextConfigUpdateShouldFail = false
    private var _eventSinceValues: [Int] = []
    private var _sessionEventSinceValues: [Int] = []
    private var _transcriptPageRequests: [(before: String?, limit: Int)] = []
    private var _transcriptPageFailuresRemaining = 0
    private var _promptQueueResponse: [ServerPromptQueueItem] = []
    private var _promptQueueGate: AsyncStream<Void>?
    private var _promptQueueRequestCount = 0
    private var _queueUpdates: [(id: String, text: String)] = []
    private var _queueDeletes: [String] = []
    private var _queueMutationFailuresRemaining = 0
    private var _goalUpdates: [(String?, GoalStatus?, TokenBudgetUpdate)] = []
    private var _goalClearCount = 0
    private var _lastBudget: Int?
    private var _questionAnswers: [(String, String, [String: QuestionAnswerEntry]?)] = []
    private var _questionAnswerGate: AsyncStream<Void>?
    // Envelope ids for scripted prompt echoes are monotonic, like the real
    // server's: repeated prompts (and test-emitted events picking ids above
    // the echoed range) must never reuse an id, or cursor-based replay in
    // `subscribeEvents` would treat distinct events as already-seen.
    private var _nextEnvelopeId = 1

    var detailConversation: [ServerConversationItem] = []
    var detailCursor = 0
    var historyEvents: [ServerEventEnvelope] = []
    var initialTranscriptPage: ServerTranscriptPage?
    var olderTranscriptPage: ServerTranscriptPage?
    var transcriptDetailsByItem: [String: ServerTranscriptItemDetails] = [:]
    /// When false, prompts are accepted without the scripted assistant echo,
    /// leaving the turn generating so tests can emit their own events.
    var echoOnPrompt = true

    init(sessionId: UUID) {
        self.sessionId = sessionId
    }

    private func yieldEvent(_ event: ServerEventEnvelope) {
        let continuations = lock.withLock {
            _eventBuffer.append(event)
            return _eventContinuations
        }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func subscribeEvents(
        since: Int
    ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ServerEventEnvelope.self)
        // Replay and registration are one atomic step against `emit`, so a
        // concurrent live yield can never overtake the replayed prefix —
        // the server's replay-then-live ordering guarantee.
        lock.withLock {
            // Mirror the server's replay semantics: live-only sentinels replay
            // nothing, cursors replay strictly newer events. Without this, a
            // resubscription after reconcile re-applies history the transcript
            // page already covers — which the real server never does.
            let liveOnly = since >= ServerSessionTransport.liveOnlyEventCursor
            for event in _eventBuffer where !liveOnly && event.id > since {
                continuation.yield(event)
            }
            _eventContinuations.append(continuation)
        }
        return stream
    }

    var promptedTexts: [String] {
        lock.withLock { _promptedTexts }
    }

    var promptedAttachments: [[ServerAttachmentRef]] {
        lock.withLock { _promptedAttachments }
    }

    var promptedMessageIds: [String?] {
        lock.withLock { _promptedMessageIds }
    }

    func holdPrompts(until gate: AsyncStream<Void>) {
        lock.withLock { _promptGate = gate }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }

    var configUpdates: [(String, String)] {
        lock.withLock { _configUpdates }
    }

    func holdConfigUpdates(until gate: AsyncStream<Void>) {
        lock.withLock { _configUpdateGate = gate }
    }

    func failNextConfigUpdate() {
        lock.withLock { _nextConfigUpdateShouldFail = true }
    }

    var eventSinceValues: [Int] {
        lock.withLock { _eventSinceValues }
    }

    var sessionEventSinceValues: [Int] {
        lock.withLock { _sessionEventSinceValues }
    }

    var transcriptPageRequests: [(before: String?, limit: Int)] {
        lock.withLock { _transcriptPageRequests }
    }

    func failNextTranscriptPages(_ count: Int) {
        lock.withLock { _transcriptPageFailuresRemaining = count }
    }

    func clearTranscriptPageFailures() {
        lock.withLock { _transcriptPageFailuresRemaining = 0 }
    }

    var promptQueueRequestCount: Int {
        lock.withLock { _promptQueueRequestCount }
    }

    func setPromptQueueResponse(_ queue: [ServerPromptQueueItem]) {
        lock.withLock { _promptQueueResponse = queue }
    }

    func holdPromptQueue(until gate: AsyncStream<Void>) {
        lock.withLock { _promptQueueGate = gate }
    }

    var queueUpdates: [(id: String, text: String)] {
        lock.withLock { _queueUpdates }
    }

    var queueDeletes: [String] {
        lock.withLock { _queueDeletes }
    }

    func failNextQueueMutation() {
        lock.withLock { _queueMutationFailuresRemaining += 1 }
    }

    var goalUpdates: [(String?, GoalStatus?, TokenBudgetUpdate)] {
        lock.withLock { _goalUpdates }
    }

    var goalClearCount: Int {
        lock.withLock { _goalClearCount }
    }

    var questionAnswers: [(String, String, [String: QuestionAnswerEntry]?)] {
        lock.withLock { _questionAnswers }
    }

    func holdQuestionAnswers(until gate: AsyncStream<Void>) {
        lock.withLock { _questionAnswerGate = gate }
    }

    private var lastBudget: Int? {
        lock.withLock { _lastBudget }
    }

    func emit(_ event: ServerEventEnvelope) {
        yieldEvent(event)
    }

    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, version: "0.1.0", database: "ready")
    }

    func listHarnesses() async throws -> [ServerHarness] { [] }
    func info() async throws -> ServerInfo { fatalError("unused") }
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        fatalError("unused")
    }
    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func listProjects() async throws -> [ServerProject] { [] }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func listSessions() async throws -> [ServerSession] { [] }
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        ServerSessionDetail(
            session: ServerSession(
                id: sessionId.uuidString,
                projectId: projectId.uuidString,
                serverId: "local",
                harnessId: "codex",
                agentSessionId: "agent-session",
                title: "Server session",
                origin: .codevisor,
                isArchived: false,
                createdAt: "2026-06-30T00:00:00.000Z",
                updatedAt: nil,
                usage: nil
            ),
            conversation: detailConversation,
            eventCursor: detailCursor
        )
    }

    func transcriptPage(id: UUID, before: String?, limit: Int) async throws -> ServerTranscriptPage {
        let shouldFail = lock.withLock {
            _transcriptPageRequests.append((before, limit))
            guard _transcriptPageFailuresRemaining > 0 else { return false }
            _transcriptPageFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
        if before == nil, let initialTranscriptPage { return initialTranscriptPage }
        if before != nil, let olderTranscriptPage { return olderTranscriptPage }
        throw CodevisorServerClientError.httpStatus(404, "")
    }

    func transcriptItemDetails(id: UUID, itemId: String) async throws -> ServerTranscriptItemDetails {
        guard let details = transcriptDetailsByItem[itemId] else {
            throw CodevisorServerClientError.httpStatus(404, "")
        }
        return details
    }

    func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] {
        let (gate, response) = lock.withLock {
            _promptQueueRequestCount += 1
            return (_promptQueueGate, _promptQueueResponse)
        }
        if let gate {
            for await _ in gate { break }
        }
        return response
    }

    func updateQueuedPrompt(
        sessionId: UUID,
        queueItemId: String,
        text: String
    ) async throws -> ServerPromptQueueItem {
        let shouldFail = lock.withLock {
            guard _queueMutationFailuresRemaining > 0 else {
                _queueUpdates.append((queueItemId, text))
                return false
            }
            _queueMutationFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
        return ServerPromptQueueItem(
            id: queueItemId,
            sessionId: sessionId.uuidString,
            text: text,
            createdAt: "2026-08-20T00:00:00.000Z",
            updatedAt: "2026-08-20T00:00:00.000Z"
        )
    }

    func deleteQueuedPrompt(sessionId _: UUID, queueItemId: String) async throws {
        let shouldFail = lock.withLock {
            guard _queueMutationFailuresRemaining > 0 else {
                _queueDeletes.append(queueItemId)
                return false
            }
            _queueMutationFailuresRemaining -= 1
            return true
        }
        if shouldFail { throw URLError(.networkConnectionLost) }
    }

    func upsertSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}

    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted
    {
        lock.withLock { _promptedAttachments.append(attachments) }
        return try await promptSession(id: id, text: text)
    }

    func promptSession(
        id: UUID, text: String, attachments: [ServerAttachmentRef], messageId: String?
    ) async throws -> ServerPromptAccepted {
        lock.withLock { _promptedMessageIds.append(messageId) }
        return try await promptSession(id: id, text: text, attachments: attachments)
    }

    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        lock.withLock { _promptedTexts.append(text) }
        if let gate = lock.withLock({ _promptGate }) {
            for await _ in gate { break }
        }
        guard echoOnPrompt else {
            return ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
        }
        yieldEvent(
            ServerEventEnvelope(
                id: nextEnvelopeId(),
                serverId: "local",
                kind: "session.output",
                subjectId: id.uuidString,
                createdAt: "2026-06-30T00:00:00.000Z",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("Echo: \(text)"),
                ])
            ))
        yieldEvent(
            ServerEventEnvelope(
                id: nextEnvelopeId(),
                serverId: "local",
                kind: "session.updated",
                subjectId: id.uuidString,
                createdAt: "2026-06-30T00:00:01.000Z",
                payload: .object([
                    "stopReason": .string("end_turn")
                ])
            ))
        return ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }

    private func nextEnvelopeId() -> Int {
        lock.withLock {
            defer { _nextEnvelopeId += 1 }
            return _nextEnvelopeId
        }
    }

    func cancelSession(id: UUID) async throws {
        lock.withLock { _cancelCount += 1 }
    }
    func setSessionMode(id: UUID, modeId: String) async throws {}

    func setSessionConfig(id: UUID, configId: String, value: String) async throws {
        let (gate, shouldFail) = lock.withLock {
            _configUpdates.append((configId, value))
            let shouldFail = _nextConfigUpdateShouldFail
            _nextConfigUpdateShouldFail = false
            return (_configUpdateGate, shouldFail)
        }
        if let gate {
            for await _ in gate { break }
        }
        if shouldFail {
            throw CodevisorServerClientError.invalidResponse
        }
    }

    @discardableResult
    func setSessionGoal(
        id: UUID,
        objective: String?,
        status: GoalStatus?,
        tokenBudget: TokenBudgetUpdate
    ) async throws -> SessionGoal {
        if objective == "goal fails" {
            throw CodevisorServerClientError.invalidResponse
        }
        let goal = SessionGoal(
            objective: objective ?? goalUpdates.last?.0 ?? "existing objective",
            status: status ?? .active,
            tokenBudget: {
                switch tokenBudget {
                case .keep: return goalUpdates.isEmpty ? nil : lastBudget
                case .clear: return nil
                case let .set(budget): return budget
                }
            }(),
            createdAt: "2026-07-05T00:00:00.000Z",
            updatedAt: "2026-07-05T00:00:00.000Z"
        )
        lock.withLock {
            _goalUpdates.append((objective, status, tokenBudget))
            _lastBudget = goal.tokenBudget
        }
        return goal
    }

    func clearSessionGoal(id: UUID) async throws {
        lock.withLock { _goalClearCount += 1 }
    }

    func answerSessionQuestion(
        id: UUID,
        questionId: String,
        outcome: String,
        answers: [String: QuestionAnswerEntry]?
    ) async throws {
        if questionId == "question-fails" {
            throw CodevisorServerClientError.invalidResponse
        }
        lock.withLock { _questionAnswers.append((questionId, outcome, answers)) }
        if let gate = lock.withLock({ _questionAnswerGate }) {
            for await _ in gate { break }
        }
    }

    func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope] {
        historyEvents
    }

    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        lock.withLock { _eventSinceValues.append(since) }
        return subscribeEvents(since: since)
    }

    func sessionEventStream(
        id: UUID,
        since: Int
    ) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        lock.withLock { _sessionEventSinceValues.append(since) }
        return subscribeEvents(since: since)
    }
}
