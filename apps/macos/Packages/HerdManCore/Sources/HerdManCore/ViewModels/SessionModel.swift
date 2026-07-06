import Foundation
import Observation
import ACPKit

/// Drives a single chat session: sends prompts, consumes the streamed
/// `SessionUpdate`s, and exposes an observable conversation for the UI.
@MainActor
@Observable
public final class SessionModel {
    public private(set) var conversation: [ConversationItem] = []
    public private(set) var isSending = false
    public private(set) var queuedPrompts: [ServerPromptQueueItem] = []
    public var composerText: String = ""
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var modeState: SessionModeState?
    public private(set) var configOptions: [SessionConfigOption]
    public private(set) var errorMessage: String?
    /// Latest context-window + cost usage reported by the agent (`usage_update`).
    public private(set) var usage: SessionUsage?
    /// Background tasks the agent is running (backgrounded shells, subagents),
    /// replaced wholesale on every server snapshot. Non-empty after a turn ends
    /// means the agent will come back on its own once the work settles.
    public private(set) var backgroundTasks: [BackgroundTaskInfo] = []

    /// True when the turn is over but the agent still owns background work —
    /// the "this chat is not stuck" signal.
    public var isWaitingOnBackgroundTasks: Bool {
        !isSending && !backgroundTasks.isEmpty
    }

    /// The session's persistent goal, when the harness supports goal mode.
    /// Snapshots are idempotent full state — each update replaces the last.
    public private(set) var goal: SessionGoal?
    /// A blocking agent question awaiting the user's answer — the composer
    /// renders as a picker while this is set. Cleared by the paired
    /// `question_resolved` event (replay collapses the pair) and at turn end.
    public private(set) var pendingQuestion: QuestionRequest?
    /// The session's latest todo checklist across turns (codex update_plan,
    /// Claude TodoWrite, ACP plan updates). Full-snapshot replace; drives the
    /// pinned panel above the composer.
    public private(set) var sessionPlan: Plan?

    private let transport: ServerSessionTransport
    private let sessionId: String
    private let now: @Sendable () -> Date
    private var serverEventCursor: Int?

    /// A single long-lived consumer of the session's event stream. The server
    /// delivers updates continuously — including agent-initiated turns with no
    /// prompt in flight — so one consumer runs for the model's lifetime.
    private var consumerTask: Task<Void, Never>?

    public init(
        serverTransport: ServerSessionTransport,
        sessionId: String,
        modeState: SessionModeState? = nil,
        configOptions: [SessionConfigOption] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = serverTransport
        self.sessionId = sessionId
        self.modeState = modeState
        self.configOptions = configOptions
        self.now = now
    }

    /// Starts the single long-lived event consumer (idempotent).
    private func startConsumer() async {
        guard consumerTask == nil else { return }
        let events = serverEventCursor.map { transport.streamEvents(since: $0) } ?? transport.streamEvents()
        consumerTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { break }
                self.apply(event)
            }
        }
    }

    /// Config options of a given category (e.g. model, thought_level, mode).
    public func configOptions(category: String) -> [SessionConfigOption] {
        configOptions.filter { $0.category == category }
    }

    /// Sets a config option's value and applies the agent's updated option set.
    public func setConfigOption(configId: String, value: String) async {
        do {
            try await transport.setConfigOption(configId: configId, value: value)
            if let index = configOptions.firstIndex(where: { $0.id == configId }) {
                configOptions[index].currentValue = value
            }
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Sends the current composer text, if any.
    public func send() async {
        await send(composerText)
    }

    /// Sends a prompt and streams the response into the conversation.
    public func send(_ text: String, attachments: [Attachment] = []) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        composerText = ""
        errorMessage = nil

        if isSending {
            await enqueueWhileSending(trimmed, attachments: attachments)
            return
        }

        conversation.append(.user(UserMessage(text: trimmed, attachments: attachments)))
        conversation.append(.assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        )))
        isSending = true

        // Events are consumed by the long-lived consumer (started here if it
        // isn't already), so every prompt — first and follow-ups — streams.
        await startConsumer()

        do {
            _ = try await transport.prompt(trimmed, attachments: attachments)
            await drain()
        } catch {
            await drain()
            errorMessage = serverErrorMessage(error)
            finish(stopReason: nil, outcome: .failed)
            isSending = false
        }
    }

    public func updateQueuedPrompt(id: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await transport.updateQueuedPrompt(id: id, text: trimmed)
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    public func deleteQueuedPrompt(id: String) async {
        do {
            try await transport.deleteQueuedPrompt(id: id)
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Requests cancellation of the in-flight turn.
    public func cancel() async {
        guard isSending else { return }
        try? await transport.cancel()
    }

    /// Switches the session mode.
    public func setMode(_ modeId: String) async {
        try? await transport.setMode(modeId)
        if var state = modeState {
            state.currentModeId = modeId
            modeState = state
        }
    }

    /// Creates or updates the session goal. The server's snapshot event
    /// reconciles the optimistic local state.
    ///
    /// Starts the event consumer first: a goal-only session (no prompt sent
    /// yet) still streams agent-initiated turns as the goal auto-continues.
    public func setGoal(
        objective: String? = nil,
        status: GoalStatus? = nil,
        tokenBudget: TokenBudgetUpdate = .keep
    ) async {
        await startConsumer()
        do {
            goal = try await transport.setGoal(
                objective: objective,
                status: status,
                tokenBudget: tokenBudget
            )
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Pauses an active goal (stops agent-side auto-continuation).
    public func pauseGoal() async {
        await setGoal(status: .paused)
    }

    /// Resumes a paused/limited goal.
    public func resumeGoal() async {
        await setGoal(status: .active)
    }

    /// Clears the session goal entirely.
    public func clearGoal() async {
        await startConsumer()
        do {
            try await transport.clearGoal()
            goal = nil
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Submits the user's answers to the pending question. The provider's
    /// `question_resolved` event confirms; local state clears optimistically.
    public func answerQuestion(answers: [String: QuestionAnswerEntry]) async {
        guard let question = pendingQuestion else { return }
        do {
            try await transport.answerQuestion(id: question.questionId, outcome: "answered", answers: answers)
            pendingQuestion = nil
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Dismisses the pending question without answering (Esc / Cancel) —
    /// the model is told the user declined to engage.
    public func cancelQuestion() async {
        guard let question = pendingQuestion else { return }
        do {
            try await transport.answerQuestion(id: question.questionId, outcome: "cancelled", answers: nil)
            pendingQuestion = nil
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    // MARK: - History

    /// Loads the server's conversation snapshot and begins live streaming from
    /// its event cursor.
    public func loadHistory() async {
        do {
            let snapshot = try await transport.snapshot()
            queuedPrompts = snapshot.promptQueue

            // Replay the persisted event history through the live pipeline —
            // the text-only conversation snapshot loses tool calls and diffs.
            // Fall back to the snapshot for sessions with no stored events.
            let history = try await transport.history()
            if history.events.isEmpty {
                conversation = snapshot.conversation
                serverEventCursor = snapshot.eventCursor
            } else {
                conversation = []
                for event in history.events {
                    apply(event)
                }
                isSending = lastTurnIsGenerating
                serverEventCursor = history.cursor ?? snapshot.eventCursor
            }
            await startConsumer()
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    private var lastTurnIsGenerating: Bool {
        if case let .assistant(message) = conversation.last {
            return message.turn.isGenerating
        }
        return false
    }

    // MARK: - Streaming

    private var appliedUpdateCount = 0

    /// Yields until the update consumer stops applying buffered updates, so the
    /// final transcript is complete before the turn is marked finished.
    private func drain() async {
        var stableRounds = 0
        var lastCount = appliedUpdateCount
        var iterations = 0
        while stableRounds < 2 && iterations < 500 {
            await Task.yield()
            iterations += 1
            if appliedUpdateCount == lastCount {
                stableRounds += 1
            } else {
                stableRounds = 0
                lastCount = appliedUpdateCount
            }
        }
    }

    private func apply(_ update: SessionUpdate) {
        appliedUpdateCount += 1
        // Plans update session-level state (the pinned todo panel) AND flow
        // into the turn below for history/replay.
        if case let .plan(plan) = update {
            sessionPlan = plan
        }
        switch update {
        case let .userMessageChunk(block, _):
            appendRemoteUserIfNeeded(text: block.textValue ?? "")
        case let .availableCommandsUpdate(commands):
            availableCommands = commands
        case let .currentModeUpdate(modeId):
            if var state = modeState {
                state.currentModeId = modeId
                modeState = state
            }
        case let .configOptionUpdate(options):
            configOptions = options
        case let .usageUpdate(usage):
            self.usage = usage
        case let .goalUpdate(goal):
            self.goal = goal
        case .goalCleared:
            goal = nil
        case let .question(request):
            pendingQuestion = request
        case let .questionResolved(resolution):
            if pendingQuestion?.questionId == resolution.questionId {
                pendingQuestion = nil
            }
            // Answered questions keep a card in the transcript flow, like
            // codex CLI's history cell; dismissed ones just disappear.
            if resolution.outcome == .answered {
                ensureAssistantTurn()
                guard case .assistant(var message) = conversation.last else { return }
                TranscriptReducer.apply(update, to: &message.turn)
                conversation[conversation.count - 1] = .assistant(message)
            }
        default:
            // Updates that belong to an earlier bubble merge there without
            // reopening it. Background subagents outlive their turn (the Agent
            // tool returns "launched" immediately), so their parented output
            // and late child settles arrive while the owning Agent section
            // sits one or more bubbles back — routing by ownership keeps that
            // section growing instead of spawning a spurious new bubble.
            if let index = owningItemIndex(for: update),
               case .assistant(var message) = conversation[index],
               !(index == conversation.count - 1 && message.turn.isGenerating) {
                TranscriptReducer.apply(update, to: &message.turn)
                conversation[index] = .assistant(message)
                return
            }
            ensureAssistantTurn()
            guard case .assistant(var message) = conversation.last else { return }
            message.turn.isGenerating = true
            isSending = true
            TranscriptReducer.apply(update, to: &message.turn)
            conversation[conversation.count - 1] = .assistant(message)
        }
    }

    /// The conversation index of the bubble that owns this update: the one
    /// holding the parent tool call for parented updates, or the tool call
    /// itself for updates addressed by id. Nil when nothing owns it (fresh
    /// output for the current or a new turn).
    private func owningItemIndex(for update: SessionUpdate) -> Int? {
        var parentId: String?
        var toolCallId: String?
        switch update {
        case let .agentMessageChunk(_, _, parent):
            parentId = parent
        case let .agentThoughtChunk(_, _, parent):
            parentId = parent
        case let .toolCall(call):
            parentId = call.parentToolCallId
        case let .toolCallUpdate(toolUpdate):
            parentId = toolUpdate.parentToolCallId
            toolCallId = toolUpdate.toolCallId
        default:
            return nil
        }
        guard parentId != nil || toolCallId != nil else { return nil }
        for index in conversation.indices.reversed() {
            guard case let .assistant(message) = conversation[index] else { continue }
            if let parentId,
               message.turn.subagents[parentId] != nil
                   || message.turn.toolCalls.contains(where: { $0.toolCallId == parentId }) {
                return index
            }
            if let toolCallId,
               message.turn.allToolCalls.contains(where: { $0.toolCallId == toolCallId }) {
                return index
            }
        }
        return nil
    }

    private func apply(_ event: ServerSessionStreamEvent) {
        switch event {
        case let .update(update):
            apply(update)
        case let .userMessage(text, attachments):
            appliedUpdateCount += 1
            appendRemoteUserIfNeeded(text: text, attachments: attachments)
        case let .finished(stopReason):
            finish(stopReason: stopReason, outcome: stopReason == .cancelled ? .cancelled : .completed)
            isSending = false
        case let .failed(message):
            errorMessage = message
            finish(stopReason: nil, outcome: .failed)
            isSending = false
        case let .queueUpdated(queue):
            queuedPrompts = queue
        case let .backgroundTasks(tasks):
            backgroundTasks = tasks
        }
    }

    /// Seeds conversation state for previews. Not for production use.
    public func applyPreviewState(conversation: [ConversationItem], isSending: Bool, usage: SessionUsage? = nil) {
        self.conversation = conversation
        self.isSending = isSending
        self.usage = usage
    }

    /// The single choke point for ending a turn: marks it finished and settles
    /// any tool calls that never received a terminal status, so in-progress
    /// indicators can't outlive the turn.
    private func finish(stopReason: StopReason?, outcome: TranscriptReducer.TurnOutcome) {
        // A question can't outlive its turn; providers emit the resolution,
        // but a dropped event must not leave the picker stuck.
        pendingQuestion = nil
        guard case .assistant(var message) = conversation.last else { return }
        message.turn.isGenerating = false
        message.turn.isThinking = false
        message.turn.stopReason = stopReason
        message.turn.endedAt = now()
        TranscriptReducer.settleToolCalls(&message.turn, outcome: outcome)
        conversation[conversation.count - 1] = .assistant(message)
    }

    private func enqueueWhileSending(_ text: String, attachments: [Attachment] = []) async {
        do {
            _ = try await transport.prompt(text, attachments: attachments)
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    private func appendRemoteUserIfNeeded(text: String, attachments: [Attachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        if conversation.count >= 2,
           case var .user(user) = conversation[conversation.count - 2],
           case let .assistant(assistant) = conversation.last,
           user.text == trimmed,
           assistant.turn.isGenerating {
            // Same-client echo of the optimistic message: stamp attachments
            // the optimistic append may not have carried.
            if user.attachments.isEmpty, !attachments.isEmpty {
                user.attachments = attachments
                conversation[conversation.count - 2] = .user(user)
            }
            return
        }
        conversation.append(.user(UserMessage(text: text, attachments: attachments)))
        conversation.append(.assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        )))
        isSending = true
    }

    private func ensureAssistantTurn() {
        if case let .assistant(message) = conversation.last {
            // A finished turn is never reopened: output arriving after the
            // stopReason means the agent started a new turn on its own (e.g. a
            // background task completing), which gets its own bubble.
            if message.turn.isGenerating { return }
        }
        conversation.append(.assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        )))
        isSending = true
    }
}
