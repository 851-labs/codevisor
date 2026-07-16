import Foundation
import Observation
import ACPKit

/// Drives a single chat session: sends prompts, consumes the streamed
/// `SessionUpdate`s, and exposes an observable conversation for the UI.
@MainActor
@Observable
public final class SessionModel {
    /// Recent history should produce a fast first paint even when a chat is
    /// made of giant markdown answers. Older rows arrive in larger reverse
    /// pages as the user approaches the top; the server also enforces a text
    /// budget so neither value can accidentally request megabytes of layout.
    private static let initialTranscriptPageSize = 8
    private static let olderTranscriptPageSize = 16
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
    public private(set) var activeItem: ConversationItem? {
        didSet { activeItemRevision &+= 1 }
    }
    /// Cheap monotonic signal for the native row host. The active bubble is
    /// deliberately observed inside its own SwiftUI subtree, so its AppKit
    /// wrapper otherwise has no reliable indication that its intrinsic height
    /// may have changed during a token flush.
    public private(set) var activeItemRevision: UInt64 = 0
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
    public private(set) var isCancelling = false
    public private(set) var queuedPrompts: [ServerPromptQueueItem] = []
    public var composerText: String = ""
    public private(set) var availableCommands: [AvailableCommand] = []
    public private(set) var modeState: SessionModeState?
    public private(set) var configOptions: [SessionConfigOption]
    public private(set) var errorMessage: String?
    /// The most recent harness-auth failure is retained separately so a
    /// duplicate generic failure carrying the same server message does not
    /// erase its recovery action.
    private var harnessAuthenticationErrorMessage: String?
    public var errorRequiresHarnessAuthentication: Bool {
        errorMessage != nil && harnessAuthenticationErrorMessage == errorMessage
    }
    /// Latest context-window + cost usage reported by the agent (`usage_update`).
    public private(set) var usage: SessionUsage?
    public private(set) var usageLimits: ServerHarnessUsageLimits?
    public private(set) var isLoadingUsageLimits = false
    public private(set) var usageLimitsError: String?
    /// Background tasks the agent is running (backgrounded shells, subagents),
    /// replaced wholesale on every server snapshot. Non-empty after a turn ends
    /// means the agent will come back on its own once the work settles.
    public private(set) var backgroundTasks: [BackgroundTaskInfo] = []
    /// Whether any snapshot has arrived yet. Terminal-tab pruning waits for
    /// this: before the first snapshot, an empty `backgroundTasks` just means
    /// history hasn't replayed, not that every task ended.
    public private(set) var hasBackgroundTaskSnapshot = false
    public private(set) var hasOlderHistory = false
    public private(set) var isLoadingOlderHistory = false
    @ObservationIgnored private var olderHistoryCursor: String?
    @ObservationIgnored private var usesPaginatedHistory = false
    @ObservationIgnored private var loadingDetailIds: Set<String> = []
    /// Constant-time routing for late/nested tool updates. Values are stable
    /// conversation ids, so prepending older pages cannot invalidate them.
    @ObservationIgnored private var toolOwnerItemIds: [String: UUID] = [:]
    @ObservationIgnored private var settledIndexById: [UUID: Int] = [:]

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
    /// True from the moment an answer or dismissal is accepted locally until
    /// the server acknowledges it. Callers use this for immediate feedback and
    /// to prevent duplicate operations while the blocking provider request is
    /// being released.
    public private(set) var isResolvingQuestion = false
    /// The session's latest todo checklist across turns (codex update_plan,
    /// Claude TodoWrite, ACP plan updates). Full-snapshot replace; drives the
    /// pinned panel above the composer.
    public private(set) var sessionPlan: Plan?

    /// Called each time a live turn ends (completed, cancelled, or failed) —
    /// the "chat finished" signal for surfaces outside this screen, like the
    /// sidebar's unread badge. Never fired by history replay.
    public var onTurnEnded: (() -> Void)?
    /// Fired when a live agent question first blocks on the user. This is
    /// separate from turn end because question tools pause an in-flight turn.
    /// Never fired while replaying transcript history.
    public var onActionRequired: (() -> Void)?
    /// Fires only after the server accepts a new prompt queue item. Carries
    /// counts/state only; prompt and attachment content never leave the model.
    public var onPromptAccepted: ((_ attachmentCount: Int, _ isQueued: Bool) -> Void)?

    private let transport: ServerSessionTransport
    private let sessionId: String
    private let now: @Sendable () -> Date
    private var serverEventCursor: Int?
    /// History contains complete config-option snapshots from the runtime that
    /// originally created the chat. During replay, retain only their selected
    /// values; the option catalog itself must come from the runtime connected
    /// today.
    private var isReplayingHistory = false
    private var historicalConfigSelections: [String: String] = [:]

    /// A single long-lived consumer of the session's event stream. The server
    /// delivers updates continuously — including agent-initiated turns with no
    /// prompt in flight — so one consumer runs for the model's lifetime.
    private var consumerTask: Task<Void, Never>?

    /// Stream events waiting for the next per-frame flush. Deliberately not
    /// observable: buffering must not invalidate views — only applying does.
    @ObservationIgnored private var pendingEvents: [ServerSessionStreamEvent] = []
    @ObservationIgnored private var isFlushScheduled = false
    /// Approximate transcript text size, seeded from history and increased by
    /// live assistant chunks. It drives adaptive stream pacing without
    /// inspecting the full transcript during every flush.
    @ObservationIgnored private var transcriptStreamBytes = 0

    /// Base interval between buffered-event flushes — roughly one frame. Tests
    /// set this to zero so their yield-based settling needs no wall-clock wait.
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
        let events: AsyncThrowingStream<ServerSessionStreamEvent, any Error>
        if usesPaginatedHistory {
            events = serverEventCursor.map { transport.streamEvents(since: $0) } ?? transport.streamEvents()
        } else {
            events = transport.legacyStreamEvents(
                since: serverEventCursor ?? ServerSessionTransport.liveOnlyEventCursor
            )
        }
        consumerTask = Task { @MainActor [weak self] in
            do {
                for try await event in events {
                    guard let self else { break }
                    self.pendingEvents.append(event)
                    self.noteStreamedSize(of: event)
                    self.scheduleFlush()
                }
                self?.flushPendingEvents()
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.session.error(
                    "Session event stream failed; reconciling from server: \(String(describing: error), privacy: .public)"
                )
                self.consumerTask = nil
                await self.reconcileFromServer()
            }
        }
    }

    private func noteStreamedSize(of event: ServerSessionStreamEvent) {
        if case let .update(.agentMessageChunk(block, _, _, _)) = event {
            transcriptStreamBytes += block.textValue?.utf8.count ?? 0
        }
    }

    /// Schedules one buffered flush. The cadence stretches as transcript text
    /// grows, keeping stream updates smooth without monopolizing the main actor.
    private func scheduleFlush() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        let interval = Self.flushInterval(
            base: Self.eventFlushInterval,
            streamedBytes: transcriptStreamBytes
        )
        Task { @MainActor [weak self] in
            if interval > .zero {
                try? await Task.sleep(for: interval)
            }
            self?.flushPendingEvents()
        }
    }

    static func flushInterval(base: Duration, streamedBytes: Int) -> Duration {
        guard base > .zero else { return base }
        switch streamedBytes {
        case ..<49_152: return base
        case ..<147_456: return base * 2
        default: return base * 3
        }
    }

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
    @discardableResult
    public func setConfigOption(configId: String, value: String) async -> Bool {
        do {
            try await transport.setConfigOption(configId: configId, value: value)
            if let index = configOptions.firstIndex(where: { $0.id == configId }) {
                configOptions[index].currentValue = value
            }
            return true
        } catch {
            errorMessage = serverErrorMessage(error)
            return false
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
        harnessAuthenticationErrorMessage = nil

        if isSending {
            await enqueueWhileSending(trimmed, attachments: attachments)
            return
        }

        settleActiveItem()
        appendSettled(.user(UserMessage(text: trimmed, attachments: attachments)))
        startActiveBubble()
        isSending = true

        // Events are consumed by the long-lived consumer (started here if it
        // isn't already), so every prompt — first and follow-ups — streams.
        await startConsumer()

        do {
            _ = try await transport.prompt(trimmed, attachments: attachments)
            onPromptAccepted?(attachments.count, false)
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
        guard isSending, !isCancelling else { return }
        isCancelling = true
        defer { isCancelling = false }
        do {
            try await transport.cancel()
        } catch {
            errorMessage = serverErrorMessage(error)
            return
        }

        // Normally the provider's terminal event arrives immediately. If it
        // was already missed (for example while the event socket was down),
        // rebuild from durable history instead of leaving a false Stop state.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            flushPendingEvents()
            if !isSending { return }
        }
        await reconcileFromServer()
    }

    private func reconcileFromServer() async {
        let wasSending = isSending
        consumerTask?.cancel()
        consumerTask = nil
        pendingEvents.removeAll(keepingCapacity: true)
        isFlushScheduled = false
        await loadHistory()
        if wasSending, !isSending {
            onTurnEnded?()
        }
    }

    /// Switches the session mode. The optimistic local update only applies
    /// when the server accepted the switch — otherwise the picker would show
    /// a mode the agent never entered.
    public func setMode(_ modeId: String) async {
        do {
            try await transport.setMode(modeId)
        } catch {
            Log.session.error(
                "Failed to set session mode \(modeId, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            errorMessage = serverErrorMessage(error)
            return
        }
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
    @discardableResult
    public func setGoal(
        objective: String? = nil,
        status: GoalStatus? = nil,
        tokenBudget: TokenBudgetUpdate = .keep
    ) async -> Bool {
        await startConsumer()
        do {
            goal = try await transport.setGoal(
                objective: objective,
                status: status,
                tokenBudget: tokenBudget
            )
            return true
        } catch {
            errorMessage = serverErrorMessage(error)
            return false
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

    /// Submits the user's answers to the pending question. Keep the request
    /// mounted until the server acknowledges it so a failure preserves the
    /// user's draft; `isResolvingQuestion` supplies the immediate UI feedback.
    public func answerQuestion(answers: [String: QuestionAnswerEntry]) async {
        guard let question = pendingQuestion, !isResolvingQuestion else { return }
        isResolvingQuestion = true
        defer { isResolvingQuestion = false }
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
        guard let question = pendingQuestion, !isResolvingQuestion else { return }
        isResolvingQuestion = true
        defer { isResolvingQuestion = false }
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
            let page = try await transport.transcriptPage(limit: Self.initialTranscriptPageSize)
            usesPaginatedHistory = true
            olderHistoryCursor = page.nextBefore
            hasOlderHistory = page.hasMore
            setConversation(page.conversation)
            if let persistedUsage = page.usage {
                usage = persistedUsage
            }
            pendingQuestion = page.pendingQuestion
            if let tasks = page.backgroundTasks {
                backgroundTasks = tasks
                hasBackgroundTaskSnapshot = true
            }
            goal = page.goal
            isSending = lastTurnIsGenerating
            transcriptStreamBytes = Self.transcriptByteEstimate(of: conversation)
            serverEventCursor = page.eventCursor
            do {
                queuedPrompts = try await transport.promptQueue()
            } catch {
                // Best-effort: history still renders without the queue.
                Log.session.error(
                    "Failed to load prompt queue: \(String(describing: error), privacy: .public)"
                )
                queuedPrompts = []
            }
            await startConsumer()
            return
        } catch let CodevisorServerClientError.httpStatus(status, _) where status == 404 {
            // Additive protocol compatibility: older remote servers keep using
            // the legacy path until they are updated.
        } catch {
            errorMessage = serverErrorMessage(error)
            return
        }

        await loadLegacyHistory()
    }

    public func loadUsageLimits(force: Bool = false) async {
        if isLoadingUsageLimits || (!force && usageLimits != nil) { return }
        isLoadingUsageLimits = true
        usageLimitsError = nil
        defer { isLoadingUsageLimits = false }
        do {
            usageLimits = try await transport.usageLimits()
        } catch {
            usageLimitsError = serverErrorMessage(error)
        }
    }

    private func loadLegacyHistory() async {
        do {
            let snapshot = try await transport.snapshot()
            queuedPrompts = snapshot.promptQueue

            // Replay the persisted event history through the live pipeline —
            // the text-only conversation snapshot loses tool calls and diffs.
            // Fall back to the snapshot for sessions with no stored events.
            let history = try await transport.history()
            if history.events.isEmpty {
                setConversation(snapshot.conversation)
                pendingQuestion = snapshot.pendingQuestion
                goal = snapshot.goal
                if let tasks = snapshot.backgroundTasks {
                    backgroundTasks = tasks
                    hasBackgroundTaskSnapshot = true
                }
                serverEventCursor = snapshot.eventCursor
            } else {
                setConversation([])
                pendingQuestion = nil
                isReplayingHistory = true
                historicalConfigSelections.removeAll(keepingCapacity: true)
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
                isReplayingHistory = false
                let runtimeOptions = configOptions
                let restoredOptions = Self.mergingSupportedSelections(
                    historicalConfigSelections,
                    into: runtimeOptions
                )
                configOptions = restoredOptions
                await restoreRuntimeConfigSelections(from: runtimeOptions, to: restoredOptions)
                isSending = lastTurnIsGenerating
                serverEventCursor = history.cursor ?? snapshot.eventCursor
            }
            transcriptStreamBytes = Self.transcriptByteEstimate(of: conversation)
            await startConsumer()
        } catch {
            isReplayingHistory = false
            errorMessage = serverErrorMessage(error)
        }
    }

    private static func mergingSupportedSelections(
        _ selections: [String: String],
        into currentOptions: [SessionConfigOption]
    ) -> [SessionConfigOption] {
        currentOptions.map { option in
            guard let selected = selections[option.id],
                  option.options.contains(where: { $0.value == selected }) else {
                return option
            }
            var merged = option
            merged.currentValue = selected
            return merged
        }
    }

    private func restoreRuntimeConfigSelections(
        from runtimeOptions: [SessionConfigOption],
        to restoredOptions: [SessionConfigOption]
    ) async {
        let runtimeValues = Dictionary(uniqueKeysWithValues: runtimeOptions.map { ($0.id, $0.currentValue) })
        let categoryOrder = [
            SessionConfigOption.Category.model: 0,
            SessionConfigOption.Category.thoughtLevel: 1,
            SessionConfigOption.Category.speed: 2
        ]
        let changed = restoredOptions
            .filter { runtimeValues[$0.id] != $0.currentValue }
            .sorted {
                (categoryOrder[$0.category ?? ""] ?? 99) < (categoryOrder[$1.category ?? ""] ?? 99)
            }
        for option in changed {
            do {
                try await transport.setConfigOption(configId: option.id, value: option.currentValue)
            } catch {
                // Best-effort restore: the remaining options still apply.
                Log.session.error(
                    "Failed to restore config option \(option.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Prepends one bounded page of older semantic rows. Requests are
    /// deduplicated and stable ids prevent overlap if a retry races a prior load.
    public func loadOlderHistory() async {
        guard usesPaginatedHistory, hasOlderHistory, !isLoadingOlderHistory,
              let cursor = olderHistoryCursor else { return }
        isLoadingOlderHistory = true
        defer { isLoadingOlderHistory = false }
        do {
            let page = try await transport.transcriptPage(
                before: cursor,
                limit: Self.olderTranscriptPageSize
            )
            let existing = Set(conversation.map(\.id))
            let unique = page.conversation.filter { !existing.contains($0.id) }
            settledConversation.insert(contentsOf: unique, at: 0)
            rebuildSettledIndex()
            transcriptStreamBytes = Self.transcriptByteEstimate(of: conversation)
            olderHistoryCursor = page.nextBefore
            hasOlderHistory = page.hasMore
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    /// Hydrates one historical assistant turn on demand. Only the bounded
    /// turn-scoped events are reduced; opening a disclosure never touches the
    /// rest of the session history.
    @discardableResult
    public func loadTranscriptDetails(itemId: String) async -> Bool {
        guard loadingDetailIds.insert(itemId).inserted else { return false }
        defer { loadingDetailIds.remove(itemId) }
        do {
            let events = try await transport.transcriptDetails(itemId: itemId)
            guard let location = transcriptItemLocation(itemId) else { return false }
            let original = location.item
            guard case let .assistant(originalMessage) = original else { return false }
            var turn = AssistantTurn(
                isGenerating: true,
                isThinking: false,
                startedAt: originalMessage.turn.startedAt
            )
            for event in events {
                switch event {
                case let .update(update):
                    TranscriptReducer.apply(update, to: &turn)
                case let .finished(reason, detail, retryable):
                    turn.stopReason = reason
                    turn.stopDetail = detail
                    turn.retryable = retryable
                    turn.isGenerating = false
                case let .failed(message), let .authenticationRequired(message):
                    turn.stopDetail = message
                    turn.isGenerating = false
                case .userMessage, .queueUpdated, .retrying, .backgroundTasks:
                    break
                }
            }
            turn.isGenerating = originalMessage.turn.isGenerating
            turn.startedAt = originalMessage.turn.startedAt
            turn.endedAt = originalMessage.turn.endedAt
            turn.planDocument = turn.planDocument ?? originalMessage.turn.planDocument
            turn.deferredDetailItemId = nil
            turn.hasDeferredWorkedDetails = false
            turn.detailRevision = originalMessage.turn.detailRevision
            let hydrated = ConversationItem.assistant(AssistantMessage(id: originalMessage.id, turn: turn))
            switch location.storage {
            case let .settled(index): settledConversation[index] = hydrated
            case .active: activeItem = hydrated
            }
            for call in turn.allToolCalls {
                toolOwnerItemIds[call.toolCallId] = originalMessage.id
            }
            return true
        } catch {
            errorMessage = serverErrorMessage(error)
            return false
        }
    }

    private enum TranscriptStorageLocation {
        case settled(Int)
        case active
    }

    private func transcriptItemLocation(
        _ itemId: String
    ) -> (storage: TranscriptStorageLocation, item: ConversationItem)? {
        if let index = settledConversation.firstIndex(where: { item in
            guard case let .assistant(message) = item else { return false }
            return message.turn.deferredDetailItemId == itemId
        }) {
            return (.settled(index), settledConversation[index])
        }
        if case let .assistant(message) = activeItem,
           message.turn.deferredDetailItemId == itemId,
           let activeItem {
            return (.active, activeItem)
        }
        return nil
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
            if isReplayingHistory {
                for option in options {
                    historicalConfigSelections[option.id] = option.currentValue
                }
            } else {
                configOptions = options
            }
        case let .usageUpdate(usage):
            self.usage = usage
        case let .goalUpdate(goal):
            self.goal = goal
        case .goalCleared:
            goal = nil
        case let .question(request):
            let isNewQuestion = pendingQuestion?.questionId != request.questionId
            pendingQuestion = request
            if isNewQuestion, !isReplayingHistory {
                onActionRequired?()
            }
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
                recordToolRoute(for: update, itemId: message.id)
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
                recordToolRoute(for: update, itemId: message.id)
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
            recordToolRoute(for: update, itemId: message.id)
        }
    }

    /// The conversation index of the bubble that owns this update. Routing is
    /// O(1) even after many history pages have been loaded.
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
        let ownerId = parentId.flatMap { toolOwnerItemIds[$0] }
            ?? toolCallId.flatMap { toolOwnerItemIds[$0] }
        guard let ownerId else { return nil }
        if activeItem?.id == ownerId { return settledConversation.count }
        return settledIndexById[ownerId]
    }

    private func recordToolRoute(for update: SessionUpdate, itemId: UUID) {
        switch update {
        case let .toolCall(call):
            toolOwnerItemIds[call.toolCallId] = itemId
        case let .toolCallUpdate(call):
            toolOwnerItemIds[call.toolCallId] = itemId
        default:
            break
        }
    }

    private func apply(_ event: ServerSessionStreamEvent) {
        switch event {
        case let .update(update):
            apply(update)
        case let .userMessage(text, attachments):
            appliedUpdateCount += 1
            appendRemoteUserIfNeeded(text: text, attachments: attachments)
        case let .finished(stopReason, stopDetail, retryable):
            finish(
                stopReason: stopReason,
                outcome: stopReason == .cancelled ? .cancelled : .completed,
                stopDetail: stopDetail,
                retryable: retryable
            )
            endTurn()
        case let .failed(message):
            errorMessage = message
            finish(stopReason: nil, outcome: .failed, stopDetail: nil)
            endTurn()
        case let .authenticationRequired(message):
            errorMessage = message
            harnessAuthenticationErrorMessage = message
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
        stopDetail: String? = nil,
        retryable: Bool = false
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
        message.turn.retryable = retryable
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
            onPromptAccepted?(attachments.count, true)
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
        appendSettled(.user(UserMessage(text: text, attachments: attachments)))
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
        appendSettled(item)
        activeItem = nil
        hasActiveItem = false
    }

    private func appendSettled(_ item: ConversationItem) {
        settledIndexById[item.id] = settledConversation.count
        settledConversation.append(item)
    }

    private func rebuildSettledIndex() {
        settledIndexById = Dictionary(
            uniqueKeysWithValues: settledConversation.enumerated().map { ($0.element.id, $0.offset) }
        )
    }

    /// Starts a fresh generating assistant bubble as the active item.
    private func startActiveBubble() {
        // A new turn (user- or agent-initiated) clears any lingering session-
        // level error banner so it can't outlive the failure it described —
        // including a stale one replayed from history on reconnect.
        errorMessage = nil
        harnessAuthenticationErrorMessage = nil
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
        rebuildSettledIndex()
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
