import Foundation
import ACPKit

extension SessionModel {
    /// Sends the current composer text, if any.
    public func send() async {
        await send(composerText)
    }

    /// Sends a prompt and streams the response into the conversation.
    public func send(_ text: String, attachments: [Attachment] = []) async {
        await send(UserMessage(text: text, attachments: attachments))
    }

    /// Sends a prompt whose client identity was created before a model was
    /// available. New-chat surfaces render this exact message optimistically
    /// while the agent starts; retaining its id here lets that same row settle
    /// in place instead of being removed and inserted a second time.
    public func send(_ outgoingMessage: UserMessage) async {
        let trimmed = outgoingMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !outgoingMessage.attachments.isEmpty else { return }
        let message = UserMessage(
            id: outgoingMessage.id,
            text: trimmed,
            attachments: outgoingMessage.attachments
        )

        composerText = ""
        errorMessage = nil
        harnessAuthenticationErrorMessage = nil

        if isSending {
            await enqueueWhileSending(trimmed, attachments: message.attachments)
            return
        }

        settleActiveItem()
        appendSettled(.user(message))
        startActiveBubble()
        isSending = true
        noteProviderActivity(.modelStream)
        onLocalUserMessageAppended?(message.id)

        // Events are consumed by the long-lived consumer (started here if it
        // isn't already), so every prompt — first and follow-ups — streams.
        await startConsumer()

        do {
            // The optimistic message's id rides along; the server adopts it,
            // so the user echo reconciles by IDENTITY (content matching is
            // only the fallback for older servers).
            _ = try await transport.prompt(
                trimmed,
                attachments: message.attachments,
                messageId: message.id.uuidString.lowercased()
            )
            onPromptAccepted?(message.attachments.count, false)
            await drain()
        } catch {
            await drain()
            let message = serverErrorMessage(error)
            errorMessage = message
            finish(stopReason: nil, outcome: .failed, stopDetail: message, retryable: true)
            lastTurnInitiator = .user
            lastTurnEndedWithError = true
            endTurn()
        }
    }

    /// Starts another assistant attempt for a failed turn without adding a
    /// duplicate user message to the visible conversation. The original
    /// message id is reused so live event replay and canonical history both
    /// reconcile the provider continuation with the existing user row.
    public func retryResponse(to prompt: UserMessage) async {
        guard !isSending else { return }

        errorMessage = nil
        harnessAuthenticationErrorMessage = nil
        settleActiveItem()
        startActiveBubble()
        isSending = true
        noteProviderActivity(.modelStream)
        await startConsumer()

        do {
            _ = try await transport.prompt(
                "Continue from the failed attempt without repeating completed work.",
                messageId: prompt.id.uuidString.lowercased()
            )
            await drain()
        } catch {
            await drain()
            let message = serverErrorMessage(error)
            errorMessage = message
            finish(stopReason: nil, outcome: .failed, stopDetail: message, retryable: true)
            lastTurnInitiator = .user
            lastTurnEndedWithError = true
            endTurn()
        }
    }

    @discardableResult
    public func updateQueuedPrompt(id: String, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await transport.updateQueuedPrompt(id: id, text: trimmed)
            return true
        } catch {
            errorMessage = serverErrorMessage(error)
            return false
        }
    }

    @discardableResult
    public func deleteQueuedPrompt(id: String) async -> Bool {
        do {
            try await transport.deleteQueuedPrompt(id: id)
            return true
        } catch {
            errorMessage = serverErrorMessage(error)
            return false
        }
    }

    /// Requests cancellation of the in-flight turn.
    public func cancel() async {
        guard isSending, !isCancelling else { return }
        isCancelling = true
        noteProviderActivity(.cancelling)
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
            try? await Task.sleep(for: Self.cancellationTerminalEventWaitDelay)
            flushPendingEvents()
            if !isSending { return }
        }
        await reconcileFromServer()
        if isSending {
            errorMessage =
                "Cancellation was accepted, but the server still reports this turn as running. Reconnect the chat and try Stop again."
        }
    }

    public func retrySessionFailure() async {
        if let recovery = connectionRecoveryTask {
            recovery.cancel()
            await recovery.value
            connectionRecoveryTask = nil
        }
        clearConnectionRecoveryPresentation()
        errorMessage = nil
        harnessAuthenticationErrorMessage = nil
        await reconcileFromServer()
    }

    /// Surfaces a failure that happened while restoring the live harness
    /// runtime after persisted history has already loaded. Keeping this state
    /// on the model lets the transcript remain visible while the chat offers
    /// the appropriate recovery action.
    public func recordSessionFailure(
        _ message: String,
        requiresHarnessAuthentication: Bool = false
    ) {
        errorMessage = message
        harnessAuthenticationErrorMessage = requiresHarnessAuthentication ? message : nil
    }

    /// Foreground/network-recovery backstop: re-verifies an in-flight turn
    /// against durable server history. Cursor replay heals a reconnected
    /// stream on its own; this covers what replay cannot — a reconcile that
    /// failed while the machine was unreachable, or a stuck durable row the
    /// server repaired while the app was suspended. No-op while idle.
    public func reconcileIfInFlight() async {
        guard isSending else { return }
        await reconcileFromServer()
    }

    /// Re-entry backstop for cached mid-turn models: a chat re-binds without
    /// reconnecting, so a turn already quiet past the stall window re-checks
    /// durable history immediately instead of waiting out the next stall
    /// cycle. Deliberately narrower than `reconcileIfInFlight` — a healthy
    /// streaming turn must not restart its consumer on every navigation.
    public func reconcileIfStalled() async {
        guard isSending, isTakingLongerThanExpected else { return }
        await reconcileFromServer()
    }

    func reconcileFromServer() async {
        // The existing loop already retries and owns presentation timing.
        // Foreground, stall, and re-entry hooks can safely converge here.
        guard connectionRecoveryTask == nil else { return }
        let outcome = await performReconciliationAttempt()
        switch outcome {
        case .loaded:
            completeConnectionRecovery()
        case .cancelled:
            return
        case let .failed(message, retryable):
            if retryable {
                beginConnectionRecovery(after: message)
            } else {
                surfaceConnectionRecoveryFailure(message)
            }
        }
    }

    private func performReconciliationAttempt() async -> SessionHistoryLoadOutcome {
        let wasSending = isSending
        consumerTask?.cancel()
        consumerTask = nil
        pendingEvents.removeAll(keepingCapacity: true)
        isFlushScheduled = false
        let outcome = await loadHistoryForConnectionRecovery()
        guard case .loaded = outcome else {
            // The cursor-backed socket is independently self-healing. Keep it
            // alive between snapshot retries so a failed GET never strands the
            // chat or hides events that resume meanwhile.
            await startConsumer()
            return outcome
        }
        if wasSending, !isSending {
            // The reload ended the turn without a terminal stream event, so
            // the event path's `endTurn` cleanup never runs — settle the
            // stall/activity state here or a healed turn keeps its stalled
            // flag (and quiet-turn timer) forever.
            stalledTurnTask?.cancel()
            stalledTurnTask = nil
            isTakingLongerThanExpected = false
            providerActivityPhase = nil
            lastTurnInitiator = .user
            lastTurnEndedWithError = errorMessage != nil
            onTurnEnded?()
        }
        return outcome
    }

    private func beginConnectionRecovery(after firstFailureMessage: String) {
        guard connectionRecoveryTask == nil else { return }
        connectionRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runConnectionRecovery(firstFailureMessage: firstFailureMessage)
        }
    }

    private func runConnectionRecovery(firstFailureMessage: String) async {
        defer { connectionRecoveryTask = nil }
        let clock = ContinuousClock()
        let startedAt = clock.now
        var failures = 1
        var latestMessage = firstFailureMessage
        var nextAttemptAt = clock.now.advanced(by: connectionRecoveryRetryDelay(failures: failures))

        while !Task.isCancelled {
            let now = clock.now
            let elapsed = now - startedAt
            updateConnectionRecoveryPresentation(elapsed: elapsed, message: latestMessage)

            if now < nextAttemptAt {
                var wait = now.duration(to: nextAttemptAt)
                if connectionRecoveryMessage == nil,
                    surfacedConnectionRecoveryError == nil,
                    elapsed < connectionRecoveryStatusDelay
                {
                    wait = min(wait, connectionRecoveryStatusDelay - elapsed)
                }
                if surfacedConnectionRecoveryError == nil,
                    elapsed < connectionRecoveryFailureDelay
                {
                    wait = min(wait, connectionRecoveryFailureDelay - elapsed)
                }
                do {
                    try await Task.sleep(for: wait)
                } catch {
                    return
                }
                continue
            }

            let outcome = await performReconciliationAttempt()
            guard !Task.isCancelled else { return }
            switch outcome {
            case .loaded:
                completeConnectionRecovery()
                return
            case .cancelled:
                return
            case let .failed(message, retryable):
                latestMessage = message
                guard retryable else {
                    surfaceConnectionRecoveryFailure(message)
                    return
                }
                failures += 1
                nextAttemptAt = clock.now.advanced(
                    by: connectionRecoveryRetryDelay(failures: failures)
                )
            }
        }
    }

    private func connectionRecoveryRetryDelay(failures: Int) -> Duration {
        let multiplier = 1 << min(max(failures - 1, 0), 5)
        return min(
            connectionRecoveryRetryMaximumDelay,
            connectionRecoveryRetryBaseDelay * multiplier
        )
    }

    private func updateConnectionRecoveryPresentation(elapsed: Duration, message: String) {
        if elapsed >= connectionRecoveryFailureDelay {
            surfaceConnectionRecoveryFailure(message)
        } else if elapsed >= connectionRecoveryStatusDelay,
            connectionRecoveryMessage == nil
        {
            connectionRecoveryMessage = "Reconnecting…"
        }
    }

    private func surfaceConnectionRecoveryFailure(_ message: String) {
        connectionRecoveryMessage = nil
        let previous = surfacedConnectionRecoveryError
        surfacedConnectionRecoveryError = message
        if errorMessage == nil || errorMessage == previous {
            errorMessage = message
        }
    }

    private func completeConnectionRecovery() {
        clearConnectionRecoveryPresentation()
    }

    func stopConnectionRecovery() {
        connectionRecoveryTask?.cancel()
        connectionRecoveryTask = nil
        clearConnectionRecoveryPresentation()
    }

    private func clearConnectionRecoveryPresentation() {
        connectionRecoveryMessage = nil
        if let surfacedConnectionRecoveryError,
            errorMessage == surfacedConnectionRecoveryError
        {
            errorMessage = nil
        }
        surfacedConnectionRecoveryError = nil
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
            onGoalChanged?()
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
            onGoalChanged?()
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

    private func enqueueWhileSending(_ text: String, attachments: [Attachment] = []) async {
        do {
            _ = try await transport.prompt(text, attachments: attachments)
            onPromptAccepted?(attachments.count, true)
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }
}
