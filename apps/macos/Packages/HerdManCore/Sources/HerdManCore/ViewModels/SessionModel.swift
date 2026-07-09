import Foundation
import Observation
import ACPKit

/// Drives a single chat session: sends prompts, consumes the streamed
/// `SessionUpdate`s, and exposes an observable conversation for the UI.
@MainActor
@Observable
public final class SessionModel {
    /// Conversation items no longer receiving stream updates. Transcript
    /// containers should iterate THIS (plus a dedicated child view for
    /// `activeItem`), never `conversation`: the settled list changes only at
    /// bubble boundaries, so token flushes stop invalidating every row.
    public private(set) var settledConversation: [ConversationItem] = []
    /// The latest assistant bubble — the one token flushes mutate. Split out
    /// of the settled list so per-flush Observation invalidation is scoped to
    /// the single view that renders it; with one stored `conversation` array,
    /// every flush re-ran the whole transcript's body + AttributeGraph diff,
    /// which is O(transcript) and made streaming feel worse with every
    /// message (profiled: ~65% of the main thread inside NSHostingView
    /// layout/render on a long chat). Stays set after its turn finishes —
    /// settling happens lazily when the NEXT bubble starts — so finalize
    /// keeps the row's view identity (collapse animation, hover state).
    public private(set) var activeItem: ConversationItem?
    /// Stored, boundary-guarded mirror of `activeItem != nil`: containers
    /// that only need existence (empty-state, setup-section placement) read
    /// this instead of `activeItem`, so they don't re-render per flush.
    public private(set) var hasActiveItem = false

    /// The full conversation in display order. Convenience for callers that
    /// want a snapshot (persistence, tests, non-body logic). Body code should
    /// prefer `settledConversation`/`activeItem` — reading this tracks both.
    public var conversation: [ConversationItem] {
        if let activeItem {
            return settledConversation + [activeItem]
        }
        return settledConversation
    }
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
    /// Whether any snapshot has arrived yet. Terminal-tab pruning waits for
    /// this: before the first snapshot, an empty `backgroundTasks` just means
    /// history hasn't replayed, not that every task ended.
    public private(set) var hasBackgroundTaskSnapshot = false

    /// Background tasks with no attachable terminal (subagents, poll-and-resume
    /// tasks). Tasks WITH a `terminalKey` render as terminal tabs instead of
    /// the waiting indicator — a dev server is running, not being waited on.
    public var waitingBackgroundTasks: [BackgroundTaskInfo] {
        backgroundTasks.filter { $0.terminalKey == nil }
    }

    /// True when the turn is over but the agent still owns background work —
    /// the "this chat is not stuck" signal. Terminal-backed tasks are excluded:
    /// their tab is the affordance.
    public var isWaitingOnBackgroundTasks: Bool {
        !isSending && !waitingBackgroundTasks.isEmpty
    }

    /// Tool-call ids of subagents still running as background tasks, keyed by
    /// the `.agent` tool call that spawned them (the provider stamps the task's
    /// `toolUseId` with the spawning call id). A subagent's turn can end while
    /// it keeps working in the background; the transcript reads this to keep its
    /// section open and its label shimmering until it leaves the snapshot.
    public var runningSubagentToolCallIds: Set<String> {
        Set(backgroundTasks.compactMap { $0.taskType == "subagent" ? $0.toolUseId : nil })
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

    /// Called each time a live turn ends (completed, cancelled, or failed) —
    /// the "chat finished" signal for surfaces outside this screen, like the
    /// sidebar's unread badge. Never fired by history replay.
    public var onTurnEnded: (() -> Void)?

    private let transport: ServerSessionTransport
    private let sessionId: String
    private let now: @Sendable () -> Date
    private var serverEventCursor: Int?

    /// A single long-lived consumer of the session's event stream. The server
    /// delivers updates continuously — including agent-initiated turns with no
    /// prompt in flight — so one consumer runs for the model's lifetime.
    private var consumerTask: Task<Void, Never>?

    /// Stream events waiting for the next per-frame flush. Deliberately not
    /// observable: buffering must not invalidate views — only applying does.
    @ObservationIgnored private var pendingEvents: [ServerSessionStreamEvent] = []
    @ObservationIgnored private var isFlushScheduled = false
    /// Bytes of assistant text this transcript has accumulated (seeded from
    /// history, grown per live chunk) — the input to the adaptive flush
    /// interval. Cumulative, never reset mid-session: per-flush render cost
    /// scales with the whole mounted transcript (every flush re-runs the
    /// display-cycle layout over the eager VStack), so a tiny new message in
    /// a long-lived chat still needs the throttled cadence. Approximate on
    /// purpose — a pacing signal, not transcript state.
    @ObservationIgnored private var transcriptStreamBytes = 0

    /// Base interval between buffered-event flushes — roughly one frame, so a
    /// streaming turn invalidates the UI at most once per frame. Tests set
    /// this to `.zero` (flush on the next main-actor turn) so their
    /// `Task.yield()`-based settling works without wall-clock waits.
    static var eventFlushInterval: Duration = .milliseconds(16)

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
    ///
    /// Events are buffered and applied in per-frame batches rather than one
    /// at a time: streaming delivers dozens of token-sized chunks per second,
    /// and each individually-applied chunk lands in its own run-loop turn —
    /// its own full SwiftUI invalidation of every `conversation` observer.
    /// Batching bounds UI work to roughly once per frame no matter how fast
    /// the server streams, which is what keeps typing in the composer crisp
    /// while a turn is running.
    private func startConsumer() async {
        guard consumerTask == nil else { return }
        let events = serverEventCursor.map { transport.streamEvents(since: $0) } ?? transport.streamEvents()
        consumerTask = Task { @MainActor [weak self] in
            for await event in events {
                guard let self else { break }
                self.pendingEvents.append(event)
                self.noteStreamedSize(of: event)
                self.scheduleFlush()
            }
            self?.flushPendingEvents()
        }
    }

    /// Tracks how much assistant text the transcript has accumulated,
    /// feeding the adaptive flush interval.
    private func noteStreamedSize(of event: ServerSessionStreamEvent) {
        if case let .update(.agentMessageChunk(block, _, _, _)) = event {
            transcriptStreamBytes += block.textValue?.utf8.count ?? 0
        }
    }

    /// Schedules a single buffered flush; no-op while one is already
    /// scheduled, so bursts of chunks coalesce into one UI update. The
    /// interval starts at ~one frame and stretches as the turn's accumulated
    /// text grows: past the settled-prefix optimizations, per-flush render
    /// work still scales with the growing block (a huge open code fence can
    /// be most of the message), and nobody can perceive 60Hz text updates
    /// anyway — pacing down multiplies every remaining per-flush cost away.
    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        let interval = Self.flushInterval(base: Self.eventFlushInterval, streamedBytes: transcriptStreamBytes)
        Task { @MainActor [weak self] in
            if interval > .zero {
                try? await Task.sleep(for: interval)
            }
            self?.flushPendingEvents()
        }
    }

    /// ~60Hz under 48KB of transcript text, ~30Hz to 144KB, ~20Hz beyond.
    /// A zero base (the test hook) stays zero.
    static func flushInterval(base: Duration, streamedBytes: Int) -> Duration {
        guard base > .zero else { return base }
        switch streamedBytes {
        case ..<49_152: return base
        case ..<147_456: return base * 2
        default: return base * 3
        }
    }

    /// Total assistant/user text bytes in a rebuilt transcript — the seed for
    /// `transcriptStreamBytes` after history replay.
    static func transcriptByteEstimate(of conversation: [ConversationItem]) -> Int {
        conversation.reduce(0) { total, item in
            switch item {
            case let .user(message):
                return total + message.text.utf8.count
            case let .assistant(message):
                return total + message.turn.entries.reduce(0) { sum, entry in
                    if case let .text(_, markdown) = entry { return sum + markdown.utf8.count }
                    return sum
                }
            }
        }
    }

    /// Applies every buffered stream event in one synchronous pass — a single
    /// run-loop turn, so SwiftUI renders the whole batch once.
    private func flushPendingEvents() {
        isFlushScheduled = false
        guard !pendingEvents.isEmpty else { return }
        let events = Self.coalesced(pendingEvents)
        pendingEvents.removeAll(keepingCapacity: true)
        for event in events {
            apply(event)
        }
    }

    /// Merges runs of adjacent text chunks addressed to the same span (same
    /// messageId, parent, and phase) into one chunk before applying. The
    /// reducer's `existing + newText` copies the whole accumulated string per
    /// applied chunk — one merged chunk costs one O(accumulated) append per
    /// flush instead of one per token, which matters once several subagents
    /// stream at once. Zero-length chunks are retro-tag markers and never
    /// merge; annotated chunks are left alone.
    static func coalesced(_ events: [ServerSessionStreamEvent]) -> [ServerSessionStreamEvent] {
        guard events.count > 1 else { return events }
        var result: [ServerSessionStreamEvent] = []
        result.reserveCapacity(events.count)
        for event in events {
            if case let .update(.agentMessageChunk(block, messageId, parent, phase)) = event,
               case let .text(text, annotations) = block, annotations == nil, !text.isEmpty,
               case let .update(.agentMessageChunk(previousBlock, previousId, previousParent, previousPhase)) =
                   result.last,
               case let .text(previousText, previousAnnotations) = previousBlock,
               previousAnnotations == nil, !previousText.isEmpty,
               messageId == previousId, parent == previousParent, phase == previousPhase {
                result[result.count - 1] = .update(.agentMessageChunk(
                    .text(previousText + text), messageId: messageId, parentToolCallId: parent, phase: phase
                ))
            } else {
                result.append(event)
            }
        }
        return result
    }

    /// Stops the live event consumer and drops any buffered events. Called
    /// when the owning controller is evicted from the session cache; a later
    /// reopen builds a fresh model that replays history and resumes the
    /// stream from its cursor.
    public func shutdown() {
        consumerTask?.cancel()
        consumerTask = nil
        pendingEvents.removeAll()
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

        settleActiveItem()
        settledConversation.append(.user(UserMessage(text: trimmed, attachments: attachments)))
        startActiveBubble()
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
            endTurn()
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
                setConversation(snapshot.conversation)
                serverEventCursor = snapshot.eventCursor
            } else {
                setConversation([])
                // Hours-long sessions replay tens of thousands of events;
                // yielding periodically keeps the run loop responsive (input,
                // rendering) instead of beachballing the app while a session
                // opens. The live consumer starts only after the loop, so no
                // stream events can interleave with the replay.
                for (index, event) in history.events.enumerated() {
                    apply(event)
                    if index % 256 == 255 {
                        await Task.yield()
                    }
                }
                isSending = lastTurnIsGenerating
                serverEventCursor = history.cursor ?? snapshot.eventCursor
            }
            // Seed the flush pacing: a reopened long chat must start at the
            // cadence its mounted size warrants, not re-earn it per chunk.
            transcriptStreamBytes = Self.transcriptByteEstimate(of: conversation)
            await startConsumer()
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    private var lastTurnIsGenerating: Bool {
        // The merged conversation's last item is the active bubble if present,
        // else the last settled one — read directly to avoid allocating the
        // whole merged array just for `.last`.
        let last = activeItem ?? settledConversation.last
        if case let .assistant(message) = last {
            return message.turn.isGenerating
        }
        return false
    }

    // MARK: - Streaming

    @ObservationIgnored private var appliedUpdateCount = 0

    /// Yields until the update consumer stops applying buffered updates, so the
    /// final transcript is complete before the turn is marked finished.
    private func drain() async {
        var stableRounds = 0
        var lastCount = appliedUpdateCount
        var iterations = 0
        while stableRounds < 2 && iterations < 500 {
            // Anything already buffered for the next frame flush counts as
            // pending work — apply it now so the stability check sees it.
            flushPendingEvents()
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
                guard case .assistant(var message) = activeItem else { return }
                TranscriptReducer.apply(update, to: &message.turn)
                activeItem = .assistant(message)
            }
        default:
            // Updates that belong to an earlier bubble merge there without
            // reopening it. Background subagents outlive their turn (the Agent
            // tool returns "launched" immediately), so their parented output
            // and late child settles arrive while the owning Agent section
            // sits one or more bubbles back — routing by ownership keeps that
            // section growing instead of spawning a spurious new bubble.
            if let index = owningItemIndex(for: update),
               case .assistant(var message) = item(at: index),
               !(index == itemCount - 1 && message.turn.isGenerating) {
                TranscriptReducer.apply(update, to: &message.turn)
                setItem(.assistant(message), at: index)
                return
            }
            ensureAssistantTurn()
            guard case .assistant(var message) = activeItem else { return }
            message.turn.isGenerating = true
            // Real content flowing means any in-flight retry succeeded — drop
            // the "Retrying…" status.
            if message.turn.retryStatus != nil { message.turn.retryStatus = nil }
            // Guarded: `@Observable` fires on every set regardless of value,
            // and this path runs for every streamed chunk — an unguarded
            // write re-renders every `isSending` observer (the composer) per
            // chunk for no state change.
            if !isSending { isSending = true }
            TranscriptReducer.apply(update, to: &message.turn)
            activeItem = .assistant(message)
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
        case let .agentMessageChunk(_, _, parent, _):
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
        // Snapshot once: `conversation` is a computed merge of
        // settledConversation + activeItem, so reading it inside the loop
        // would rebuild the whole array every iteration (O(n²) per chunk).
        let items = conversation
        for index in items.indices.reversed() {
            guard case let .assistant(message) = items[index] else { continue }
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
        case let .finished(stopReason, stopDetail):
            finish(
                stopReason: stopReason,
                outcome: stopReason == .cancelled ? .cancelled : .completed,
                stopDetail: stopDetail
            )
            endTurn()
        case let .failed(message):
            errorMessage = message
            finish(stopReason: nil, outcome: .failed, stopDetail: nil)
            endTurn()
        case let .retrying(retry):
            // A transient failure is being retried — the turn is still alive.
            // Surface it on the active turn so the UI shows "Retrying… (n/of)".
            ensureAssistantTurn()
            guard case .assistant(var message) = activeItem else { return }
            message.turn.isGenerating = true
            message.turn.retryStatus = retry
            activeItem = .assistant(message)
            if !isSending { isSending = true }
        case let .queueUpdated(queue):
            queuedPrompts = queue
        case let .backgroundTasks(tasks):
            backgroundTasks = tasks
            hasBackgroundTaskSnapshot = true
        }
    }

    /// Seeds conversation state for previews. Not for production use.
    public func applyPreviewState(conversation: [ConversationItem], isSending: Bool, usage: SessionUsage? = nil) {
        setConversation(conversation)
        self.isSending = isSending
        self.usage = usage
    }

    /// The single choke point for ending a turn: marks it finished and settles
    /// any tool calls that never received a terminal status, so in-progress
    /// indicators can't outlive the turn.
    private func finish(
        stopReason: StopReason?,
        outcome: TranscriptReducer.TurnOutcome,
        stopDetail: String? = nil
    ) {
        // A question can't outlive its turn; providers emit the resolution,
        // but a dropped event must not leave the picker stuck.
        pendingQuestion = nil
        guard case .assistant(var message) = activeItem else { return }
        message.turn.isGenerating = false
        message.turn.isThinking = false
        message.turn.retryStatus = nil
        message.turn.stopReason = stopReason
        // Present only when the turn ended abnormally; drives the per-turn reason
        // line so a non-clean stop is never silent.
        message.turn.stopDetail = stopDetail
        message.turn.endedAt = now()
        TranscriptReducer.settleToolCalls(&message.turn, outcome: outcome)
        // Stays the active item: settling happens when the next bubble
        // starts, so the row keeps its view identity through the finalize
        // collapse.
        activeItem = .assistant(message)
    }

    /// Clears the sending flag and fires `onTurnEnded` — only when a turn was
    /// actually in flight, so redundant terminal events don't double-notify.
    private func endTurn() {
        let wasSending = isSending
        isSending = false
        if wasSending { onTurnEnded?() }
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
        if case var .user(user) = settledConversation.last,
           case let .assistant(assistant) = activeItem,
           user.text == trimmed,
           assistant.turn.isGenerating {
            // Same-client echo of the optimistic message: stamp attachments
            // the optimistic append may not have carried.
            if user.attachments.isEmpty, !attachments.isEmpty {
                user.attachments = attachments
                settledConversation[settledConversation.count - 1] = .user(user)
            }
            return
        }
        settleActiveItem()
        settledConversation.append(.user(UserMessage(text: text, attachments: attachments)))
        startActiveBubble()
        if !isSending { isSending = true }
    }

    private func ensureAssistantTurn() {
        if case let .assistant(message) = activeItem {
            // A finished turn is never reopened: output arriving after the
            // stopReason means the agent started a new turn on its own (e.g. a
            // background task completing), which gets its own bubble.
            if message.turn.isGenerating { return }
        }
        settleActiveItem()
        startActiveBubble()
        if !isSending { isSending = true }
    }

    // MARK: - Settled/active storage

    /// Moves the active bubble into the settled list. Called only at bubble
    /// boundaries, so `settledConversation` (and the boundary-guarded
    /// `hasActiveItem`) never change on a token flush.
    private func settleActiveItem() {
        guard let item = activeItem else { return }
        settledConversation.append(item)
        activeItem = nil
        hasActiveItem = false
    }

    /// Starts a fresh generating assistant bubble as the active item.
    private func startActiveBubble() {
        // A new turn (user- or agent-initiated) clears any lingering session-
        // level error banner so it can't outlive the failure it described —
        // including a stale one replayed from history on reconnect.
        errorMessage = nil
        activeItem = .assistant(AssistantMessage(
            turn: AssistantTurn(isGenerating: true, isThinking: true, startedAt: now())
        ))
        if !hasActiveItem { hasActiveItem = true }
    }

    /// Replaces conversation state wholesale (history load, previews). The
    /// trailing assistant bubble stays active so live streaming resumes into
    /// the same storage slot the transcript's active row renders.
    private func setConversation(_ items: [ConversationItem]) {
        if case .assistant = items.last {
            settledConversation = Array(items.dropLast())
            activeItem = items.last
            if !hasActiveItem { hasActiveItem = true }
        } else {
            settledConversation = items
            activeItem = nil
            if hasActiveItem { hasActiveItem = false }
        }
    }

    /// Read/replace by display index (settled items first, then the active
    /// bubble) — the addressing `owningItemIndex` hands back.
    private func item(at index: Int) -> ConversationItem? {
        if index < settledConversation.count { return settledConversation[index] }
        if index == settledConversation.count { return activeItem }
        return nil
    }

    private func setItem(_ item: ConversationItem, at index: Int) {
        if index < settledConversation.count {
            settledConversation[index] = item
        } else if index == settledConversation.count, activeItem != nil {
            activeItem = item
        }
    }

    private var itemCount: Int {
        settledConversation.count + (activeItem == nil ? 0 : 1)
    }
}
