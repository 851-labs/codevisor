import Foundation
import ACPKit

enum SessionHistoryLoadOutcome {
    case loaded
    case cancelled
    case failed(message: String, retryable: Bool)
}

extension SessionModel {
    // MARK: - History

    /// Loads the server's conversation snapshot and begins live streaming from
    /// its event cursor. A `preloaded` page (fetched by the combined open
    /// call) skips the transcript round-trip entirely; the consumer still
    /// resumes from the page's own event cursor, so nothing between the
    /// page's snapshot and "now" is skipped.
    public func loadHistory(preloaded: TranscriptHistoryPage? = nil) async {
        surfaceHistoryLoadFailure(
            await loadHistoryOnce(preloaded: preloaded, defersPromptQueue: false)
        )
    }

    /// Initial navigation only needs the transcript page to paint. Queue state
    /// is auxiliary composer chrome, so fetch it after streaming has started
    /// without extending selection-to-transcript latency.
    func loadHistoryForInitialDisplay(preloaded: TranscriptHistoryPage? = nil) async {
        surfaceHistoryLoadFailure(
            await loadHistoryOnce(preloaded: preloaded, defersPromptQueue: true)
        )
    }

    /// One non-presenting snapshot attempt for connection recovery. The
    /// recovery loop owns retry timing and decides when a failure becomes
    /// user-visible; ordinary history loads keep their immediate error UI.
    func loadHistoryForConnectionRecovery() async -> SessionHistoryLoadOutcome {
        await loadHistoryOnce(preloaded: nil, defersPromptQueue: false)
    }

    private func loadHistoryOnce(
        preloaded: TranscriptHistoryPage?,
        defersPromptQueue: Bool
    ) async -> SessionHistoryLoadOutcome {
        promptQueueLoadTask?.cancel()
        promptQueueLoadTask = nil
        do {
            let page: TranscriptHistoryPage
            if let preloaded {
                page = preloaded
            } else {
                page = try await transport.transcriptPage(limit: Self.initialTranscriptPageSize)
            }
            usesPaginatedHistory = true
            olderHistoryCursor = page.nextBefore
            hasOlderHistory = page.hasMore
            setConversation(page.conversation)
            if let persistedUsage = page.usage {
                usage = persistedUsage
            }
            pendingQuestion = page.pendingQuestion
            pendingPlanApproval = page.pendingPlanApproval
            if let tasks = page.backgroundTasks {
                backgroundTasks = tasks
                hasBackgroundTaskSnapshot = true
            }
            goal = page.goal
            isSending = lastTurnIsGenerating
            if isSending { noteProviderActivity(.modelStream) }
            transcriptStreamBytes = TranscriptReducer.transcriptByteEstimate(of: conversation)
            serverEventCursor = page.eventCursor
            if defersPromptQueue {
                await startConsumer()
                schedulePromptQueueLoad()
            } else {
                await loadPromptQueue(ifUnchangedSince: promptQueueRevision)
                await startConsumer()
            }
            return .loaded
        } catch let CodevisorServerClientError.httpStatus(status, _) where status == 404 {
            // Additive protocol compatibility: older remote servers keep using
            // the legacy path until they are updated.
        } catch {
            // A cancelled load is the view going away (pane re-hosted, tab
            // switched), not a failure — the remounted view reloads history
            // itself. Surfacing it painted "cancelled" errors into every chat
            // whenever the workspace layout churned during a reload.
            return historyLoadOutcome(for: error)
        }

        return await loadLegacyHistory()
    }

    private func surfaceHistoryLoadFailure(_ outcome: SessionHistoryLoadOutcome) {
        guard case let .failed(message, _) = outcome else { return }
        errorMessage = message
    }

    private func historyLoadOutcome(for error: any Error) -> SessionHistoryLoadOutcome {
        if isTaskCancellation(error) { return .cancelled }
        let retryable: Bool
        if let serverError = error as? CodevisorServerClientError {
            switch serverError {
            case let .httpStatus(status, _):
                retryable = status == 408 || status == 425 || status == 429 || status >= 500
            case .invalidURL, .invalidResponse, .invalidDate, .invalidUUID:
                retryable = false
            }
        } else {
            // Transport failures (including cloud relay channel loss) are
            // transient unless the server supplied a terminal HTTP response.
            retryable = true
        }
        return .failed(message: serverErrorMessage(error), retryable: retryable)
    }

    private func schedulePromptQueueLoad() {
        let revision = promptQueueRevision
        promptQueueLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadPromptQueue(ifUnchangedSince: revision)
            if !Task.isCancelled {
                self.promptQueueLoadTask = nil
            }
        }
    }

    private func loadPromptQueue(ifUnchangedSince revision: UInt64) async {
        do {
            let queue = try await transport.promptQueue()
            guard !Task.isCancelled, revision == promptQueueRevision else { return }
            queuedPrompts = queue
            promptQueueRevision &+= 1
        } catch {
            guard !isTaskCancellation(error) else { return }
            // Best-effort: history still renders without the queue. Only clear
            // the snapshot when no newer stream event has already replaced it.
            Log.session.error(
                "Failed to load prompt queue: \(String(describing: error), privacy: .public)"
            )
            guard revision == promptQueueRevision else { return }
            queuedPrompts = []
            promptQueueRevision &+= 1
        }
    }

    /* Usage-limit loading only feeds the temporarily disabled usage popover.
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
    */

    private func loadLegacyHistory() async -> SessionHistoryLoadOutcome {
        do {
            let snapshot = try await transport.snapshot()
            queuedPrompts = snapshot.promptQueue
            promptQueueRevision &+= 1

            // Replay the persisted event history through the live pipeline —
            // the text-only conversation snapshot loses tool calls and diffs.
            // Fall back to the snapshot for sessions with no stored events.
            let history = try await transport.history()
            if history.events.isEmpty {
                setConversation(snapshot.conversation)
                pendingQuestion = snapshot.pendingQuestion
                pendingPlanApproval = snapshot.pendingPlanApproval
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
                if isSending { noteProviderActivity(.modelStream) }
                serverEventCursor = history.cursor ?? snapshot.eventCursor
            }
            transcriptStreamBytes = TranscriptReducer.transcriptByteEstimate(of: conversation)
            await startConsumer()
            return .loaded
        } catch {
            isReplayingHistory = false
            return historyLoadOutcome(for: error)
        }
    }

    private static func mergingSupportedSelections(
        _ selections: [String: String],
        into currentOptions: [SessionConfigOption]
    ) -> [SessionConfigOption] {
        currentOptions.map { option in
            guard let selected = selections[option.id],
                option.options.contains(where: { $0.value == selected })
            else {
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
            SessionConfigOption.Category.speed: 2,
        ]
        let changed =
            restoredOptions
            .filter { runtimeValues[$0.id] != $0.currentValue }
            .sorted {
                (categoryOrder[$0.category ?? ""] ?? 99) < (categoryOrder[$1.category ?? ""] ?? 99)
            }
        for option in changed {
            do {
                _ = try await transport.setConfigOption(
                    configId: option.id,
                    value: option.currentValue
                )
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
    @discardableResult
    public func loadOlderHistory() async -> Int {
        guard usesPaginatedHistory, hasOlderHistory, !isLoadingOlderHistory,
            let cursor = olderHistoryCursor
        else { return 0 }
        isLoadingOlderHistory = true
        defer { isLoadingOlderHistory = false }
        do {
            let page = try await transport.transcriptPage(
                before: cursor,
                limit: Self.olderTranscriptPageSize
            )
            let existing = Set(conversation.map(\.id))
            let unique = page.conversation.filter {
                $0.hasRenderableTranscriptContent && !existing.contains($0.id)
            }
            settledConversation.insert(contentsOf: unique, at: 0)
            rebuildSettledIndex()
            transcriptStreamBytes = TranscriptReducer.transcriptByteEstimate(of: conversation)
            olderHistoryCursor = page.nextBefore
            hasOlderHistory = page.hasMore
            return unique.count
        } catch {
            if !isTaskCancellation(error) {
                errorMessage = serverErrorMessage(error)
            }
            return 0
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
                case let .assistantFinalized(markdown, messageId, attachments):
                    TranscriptReducer.finalizeAssistant(
                        markdown: markdown,
                        messageId: messageId,
                        attachments: attachments,
                        to: &turn
                    )
                case let .finished(reason, detail, retryable, _, _):
                    turn.stopReason = reason
                    turn.stopDetail = detail
                    turn.retryable = retryable
                    turn.isGenerating = false
                case let .failed(message, retryable, _):
                    turn.stopDetail = message
                    turn.retryable = retryable
                    turn.isGenerating = false
                case let .authenticationRequired(message):
                    turn.stopDetail = message
                    turn.isGenerating = false
                case .assistantItemStarted:
                    break
                // `modelFallback` is session-level state, not per-turn detail:
                // replaying history must not resurrect a dismissed notice.
                case .userMessage, .queueUpdated, .retrying, .backgroundTasks, .runtimeState,
                    .planApprovalRequired, .updateGate, .modelFallback:
                    break
                }
            }
            turn.isGenerating = originalMessage.turn.isGenerating
            turn.startedAt = originalMessage.turn.startedAt
            turn.endedAt = originalMessage.turn.endedAt
            turn.planDocument = turn.planDocument ?? originalMessage.turn.planDocument
            if turn.attachments.isEmpty { turn.attachments = originalMessage.turn.attachments }
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
            if !isTaskCancellation(error) {
                errorMessage = serverErrorMessage(error)
            }
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
            let activeItem
        {
            return (.active, activeItem)
        }
        return nil
    }

    private var lastTurnIsGenerating: Bool {
        // The merged conversation's last item is the active bubble if present,
        // else the last settled one — read directly to avoid allocating the
        // whole merged array just for `.last`.
        if case let .assistant(message) = activeItem {
            if message.turn.isGenerating { return true }
        }
        // A generating bubble can also sit mid-transcript: a user row that
        // landed after an agent-initiated turn's bubble pushes it off the
        // tail while its turn is still live. Any generating bubble means the
        // session is busy; the server heals genuinely stale rows itself, so
        // this cannot latch on dead history.
        return settledConversation.reversed().contains { item in
            if case let .assistant(message) = item { return message.turn.isGenerating }
            return false
        }
    }
}
