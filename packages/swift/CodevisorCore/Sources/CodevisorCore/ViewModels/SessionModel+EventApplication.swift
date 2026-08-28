import Foundation
import ACPKit

extension SessionModel {
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
            if !isReplayingHistory { onGoalChanged?() }
        case .goalCleared:
            goal = nil
            if !isReplayingHistory { onGoalChanged?() }
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
                !(index == itemCount - 1 && message.turn.isGenerating)
            {
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
        let ownerId =
            parentId.flatMap { toolOwnerItemIds[$0] }
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

    func apply(_ event: ServerSessionStreamEvent) {
        // Any real session event proves the cursor-backed transport recovered.
        // Keep snapshot reconciliation as a backstop only while the stream is
        // actually quiet; never leave Reconnecting/error UI over live output.
        if !isReplayingHistory, connectionRecoveryTask != nil {
            stopConnectionRecovery()
        }
        if !isReplayingHistory, let phase = providerActivityPhase(for: event) {
            noteProviderActivity(phase)
        }
        switch event {
        case let .update(update):
            apply(update)
        case let .assistantItemStarted(itemId):
            ensureAssistantTurn()
            adoptActiveAssistantItemIdentity(itemId)
        case let .assistantFinalized(markdown, messageId, attachments):
            ensureAssistantTurn()
            guard case .assistant(var message) = activeItem else { return }
            TranscriptReducer.finalizeAssistant(
                markdown: markdown,
                messageId: messageId,
                attachments: attachments,
                to: &message.turn
            )
            activeItem = .assistant(message)
            appliedUpdateCount += 1
        case let .userMessage(id, text, attachments):
            appliedUpdateCount += 1
            let promotedFromQueue = consumeQueuePromotion(id: id)
            appendRemoteUserIfNeeded(id: id, text: text, attachments: attachments)
            if promotedFromQueue {
                onQueuedPromptPromoted?(id.flatMap(UUID.init(uuidString:)))
            }
        case let .finished(stopReason, stopDetail, stopKind, retryable, initiatedBy, chatItemId):
            let activeTurnContinues = finish(
                stopReason: stopReason,
                outcome: stopReason == .cancelled ? .cancelled : .completed,
                stopDetail: stopDetail,
                stopKind: stopKind,
                retryable: retryable,
                chatItemId: chatItemId
            )
            lastTurnInitiator = initiatedBy
            lastTurnEndedWithError =
                stopDetail != nil
                || (stopReason != .endTurn && stopReason != .cancelled)
            if !activeTurnContinues { endTurn() }
        case let .failed(message, retryable, chatItemId):
            errorMessage = message
            let activeTurnContinues = finish(
                stopReason: nil,
                outcome: .failed,
                stopDetail: message,
                retryable: retryable,
                chatItemId: chatItemId
            )
            lastTurnInitiator = .user
            lastTurnEndedWithError = true
            if !activeTurnContinues { endTurn() }
        case let .authenticationRequired(message):
            errorMessage = message
            harnessAuthenticationErrorMessage = message
            finish(stopReason: nil, outcome: .failed, stopDetail: message)
            lastTurnInitiator = .user
            lastTurnEndedWithError = true
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
            applyQueuedPromptSnapshot(queue)
        case let .updateGate(waiting, harnessName):
            updateGateHarnessName = waiting ? harnessName : nil
        case let .backgroundTasks(tasks):
            backgroundTasks = tasks
            hasBackgroundTaskSnapshot = true
        case let .runtimeState(state):
            runtimeState = state
            onRuntimeStateChanged?()
        case let .planApprovalRequired(required):
            pendingPlanApproval = required
            onPlanApprovalChanged?(required)
        case let .modelFallback(fallback):
            modelFallback = fallback
        }
    }

    /// Drops the refusal-fallback notice. Called on user dismissal and when the
    /// user selects a model themselves, which makes the notice stale.
    public func clearModelFallback() {
        modelFallback = nil
    }

    /// The single choke point for ending a turn: marks it finished and settles
    /// any tool calls that never received a terminal status, so in-progress
    /// indicators can't outlive the turn.
    ///
    /// Terminal events are routed by the server-owned chat-item identity when
    /// one is present — the same `turn:{turnId}` → item routing the server
    /// projection uses. A bubble that was settled while still generating
    /// (e.g. a user row interleaved with an agent-initiated turn) is closed
    /// in place instead of stranding its "Worked for…" spinner forever.
    /// Returns true when the closure landed on a settled bubble while a
    /// NEWER active bubble is still generating — the session is still busy,
    /// so the caller must not clear the sending state.
    @discardableResult
    func finish(
        stopReason: StopReason?,
        outcome: TranscriptReducer.TurnOutcome,
        stopDetail: String? = nil,
        stopKind: String? = nil,
        retryable: Bool = false,
        chatItemId: UUID? = nil
    ) -> Bool {
        if let chatItemId,
            activeItem?.id != chatItemId,
            let index = settledIndexById[chatItemId],
            case .assistant(var settled) = settledConversation[index]
        {
            closeTurn(
                &settled.turn,
                stopReason: stopReason,
                outcome: outcome,
                stopDetail: stopDetail,
                stopKind: stopKind,
                retryable: retryable
            )
            settledConversation[index] = .assistant(settled)
            // The active bubble belongs to a newer turn: leave the session-
            // level state (pending question, sending flag) to that turn's own
            // terminal event.
            if case let .assistant(active) = activeItem, active.turn.isGenerating {
                return true
            }
            pendingQuestion = nil
            return false
        }
        // A question can't outlive its turn; providers emit the resolution,
        // but a dropped event must not leave the picker stuck.
        pendingQuestion = nil
        guard case .assistant(var message) = activeItem else { return false }
        closeTurn(
            &message.turn,
            stopReason: stopReason,
            outcome: outcome,
            stopDetail: stopDetail,
            stopKind: stopKind,
            retryable: retryable
        )
        // Stays the active item: settling happens when the next bubble
        // starts, so the row keeps its view identity through the finalize
        // collapse.
        activeItem = .assistant(message)
        return false
    }

    private func closeTurn(
        _ turn: inout AssistantTurn,
        stopReason: StopReason?,
        outcome: TranscriptReducer.TurnOutcome,
        stopDetail: String?,
        stopKind: String? = nil,
        retryable: Bool
    ) {
        turn.isGenerating = false
        turn.isThinking = false
        turn.retryStatus = nil
        turn.stopReason = stopReason
        // Present only when the turn ended abnormally; drives the per-turn reason
        // line so a non-clean stop is never silent.
        turn.stopDetail = stopDetail
        turn.stopKind = stopKind
        turn.retryable = retryable
        turn.endedAt = now()
        TranscriptReducer.settleToolCalls(&turn, outcome: outcome)
    }

    /// Clears the sending flag and fires `onTurnEnded` — only when a turn was
    /// actually in flight, so redundant terminal events don't double-notify.
    func endTurn() {
        let wasSending = isSending
        isSending = false
        stopConnectionRecovery()
        stalledTurnSchedule?.cancel()
        stalledTurnSchedule = nil
        isTakingLongerThanExpected = false
        providerActivityPhase = nil
        if wasSending { onTurnEnded?() }
    }

    func noteProviderActivity(_ phase: SessionProviderActivityPhase) {
        // Guarded for the same reason `isSending` is in `apply(_ update:)`:
        // `@Observable` fires on every set regardless of value, and this runs
        // for EVERY applied stream event. The composer is the only reader of
        // both properties, so unguarded writes re-rendered the whole composer
        // card — text view, model/harness menus, glass surface — at stream
        // rate, which is what made typing feel buffered while chats ran.
        //
        // The quiet-turn timer below is deliberately NOT part of the guard: it
        // must be cancelled and re-armed on every activity event, or a turn
        // that streams steadily under one phase would keep the task armed by
        // its FIRST chunk and falsely report itself stalled mid-stream.
        if providerActivityPhase != phase { providerActivityPhase = phase }
        if isTakingLongerThanExpected { isTakingLongerThanExpected = false }
        stalledTurnSchedule?.cancel()
        let quietInterval = stalledTurnQuietInterval
        stalledTurnSchedule = quietTurnScheduler.schedule(quietInterval) { [weak self] in
            guard let self, self.isSending else { return }
            self.isTakingLongerThanExpected = true
            // A turn this quiet may be dead in a way no transport signal
            // caught, or its terminal event may have been lost. Re-derive the
            // truth from durable history: a genuinely finished turn clears
            // its spinner here (snapshot + cursor resume), while a live-but-
            // quiet turn reloads to the same state. Without this, a missed
            // terminal event spins forever on platforms that render no stall
            // affordance.
            await self.reconcileFromServer()
            // Reloading notes synthetic activity, which clears the flag,
            // re-arms the quiet window, and cancels this task — deliberately
            // not guarded on cancellation here. A turn still live after the
            // reload is still stalled: keep the notice up instead of blinking
            // it off for a full window each cycle. Real activity clears it.
            if self.isSending { self.isTakingLongerThanExpected = true }
        }
    }

    private func providerActivityPhase(
        for event: ServerSessionStreamEvent
    ) -> SessionProviderActivityPhase? {
        switch event {
        case let .update(update):
            switch update {
            case .agentMessageChunk, .agentThoughtChunk, .plan, .planDocument:
                return .modelStream
            case .toolCall:
                return .toolInputStream
            case .toolCallUpdate:
                return .toolExecution
            case .question:
                return .waitingForQuestion
            case .questionResolved:
                return .toolExecution
            case .contextCompaction:
                return .modelStream
            case .userMessageChunk, .availableCommandsUpdate, .currentModeUpdate,
                .configOptionUpdate, .usageUpdate, .goalUpdate, .goalCleared:
                return nil
            }
        case .retrying:
            return .retryBackoff
        case .userMessage:
            return .modelStream
        case .assistantItemStarted:
            return .modelStream
        case .assistantFinalized:
            return .modelStream
        case .finished, .failed, .authenticationRequired, .queueUpdated, .updateGate,
            .backgroundTasks, .runtimeState, .planApprovalRequired, .modelFallback:
            return nil
        }
    }

    private func appendRemoteUserIfNeeded(
        id: String? = nil,
        text: String,
        attachments: [Attachment] = []
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // IDENTITY first: the prompt carried the optimistic message's id and
        // the server echoed it back — this IS that message, wherever it sits
        // and whatever the agent did in between. Stamp attachments the
        // optimistic append may not have carried.
        if let echoId = id.flatMap(UUID.init(uuidString:)),
            let index = settledConversation.lastIndex(where: { item in
                if case let .user(user) = item { return user.id == echoId }
                return false
            })
        {
            if case var .user(user) = settledConversation[index],
                user.attachments.isEmpty, !attachments.isEmpty
            {
                user.attachments = attachments
                settledConversation[index] = .user(user)
            }
            pendingOptimisticUserMessageIDs.remove(echoId)
            return
        }
        // CONTENT fallback (older servers that don't echo the client id).
        // Restrict it to rows this client actually appended optimistically.
        // Repeated queue prompts and messages from another client are distinct
        // turns even when their text is identical.
        if let index = settledConversation.lastIndex(where: { item in
            guard case let .user(user) = item else { return false }
            return pendingOptimisticUserMessageIDs.contains(user.id)
                && user.text == trimmed
        }), case var .user(user) = settledConversation[index] {
            if user.attachments.isEmpty, !attachments.isEmpty {
                user.attachments = attachments
                settledConversation[index] = .user(user)
            }
            pendingOptimisticUserMessageIDs.remove(user.id)
            return
        }
        settleActiveItem()
        appendSettled(
            .user(
                UserMessage(
                    id: id.flatMap(UUID.init(uuidString:)) ?? UUID(),
                    text: text,
                    attachments: attachments
                )))
        startActiveBubble()
        if !isSending { isSending = true }
    }

    func applyQueuedPromptSnapshot(_ queue: [ServerPromptQueueItem]) {
        rememberRemovedQueueItems(in: queue)
        queuedPrompts = queue
        promptQueueRevision &+= 1
        onQueuedPromptsChanged?()
    }

    private func rememberRemovedQueueItems(in updatedQueue: [ServerPromptQueueItem]) {
        let now = ProcessInfo.processInfo.systemUptime
        pendingQueuePromotionIDs = pendingQueuePromotionIDs.filter { $0.value > now }
        let updatedIDs = Set(updatedQueue.map(\.id))
        for item in queuedPrompts where !updatedIDs.contains(item.id) {
            pendingQueuePromotionIDs[item.id] = now + 5
        }
        // A pathological sequence of remote deletes should not leave an
        // unbounded side table while no further queue events arrive.
        if pendingQueuePromotionIDs.count > 32 {
            let newest =
                pendingQueuePromotionIDs
                .sorted { $0.value > $1.value }
                .prefix(32)
                .map { ($0.key, $0.value) }
            pendingQueuePromotionIDs = Dictionary(uniqueKeysWithValues: newest)
        }
    }

    private func consumeQueuePromotion(id: String?) -> Bool {
        guard let id else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard let deadline = pendingQueuePromotionIDs.removeValue(forKey: id),
            deadline > now
        else { return false }
        return true
    }

    func ensureAssistantTurn() {
        // User output is ordered before assistant output. Once provider output
        // begins, an unmatched optimistic row is no longer awaiting an echo;
        // retaining it could make a later equal queue/remote prompt look like
        // that echo.
        pendingOptimisticUserMessageIDs.removeAll()
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
}
