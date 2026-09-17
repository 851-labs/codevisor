import Foundation
import ACPKit

enum SessionHistoryLoadOutcome {
  case loaded
  case cancelled
  case failed(message: String, retryable: Bool)
}

extension SessionModel {
  public func transcriptBodyPage(
    resource: ToolDetailResource, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    try await transport.transcriptBodyPage(resource: resource, field: field, position: position)
  }

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
    await loadHistoryOnce(preloaded: nil, defersPromptQueue: false, preservingContent: true)
  }

  private func loadHistoryOnce(
    preloaded: TranscriptHistoryPage?,
    defersPromptQueue: Bool,
    preservingContent: Bool = false
  ) async -> SessionHistoryLoadOutcome {
    promptQueueLoadTask?.cancel()
    promptQueueLoadTask = nil
    do {
      var page: TranscriptHistoryPage
      if let preloaded {
        page = preloaded
      } else {
        page = try await transport.transcriptPage(limit: Self.initialTranscriptPageSize)
      }
      usesPaginatedHistory = true
      if appliedStateIsCurrent(through: page.eventCursor) {
        // Everything this snapshot describes has already been applied
        // from the live stream (and possibly more). Installing it would
        // rewind the visible turn to an older prefix and then replay the
        // difference — the transcript "shrinks and re-types" — for no
        // information gain. Keep the applied state and just make sure the
        // stream is running from where it left off.
        Log.session.notice(
          "Skipped a history snapshot at cursor \(page.eventCursor, privacy: .public); live stream already applied through \(String(describing: self.serverEventCursor), privacy: .public)"
        )
        if preservingContent { applySynchronization(.catchingUp) }
        await startConsumer()
        if defersPromptQueue {
          schedulePromptQueueLoad()
        } else {
          await loadPromptQueue(ifUnchangedSince: promptQueueRevision)
        }
        return .loaded
      }
      page = try await transport.completeHistoryPage(page, limit: Self.initialTranscriptPageSize)
      if preservingContent {
        let hydratedIDs = Set(
          conversation.compactMap { item -> UUID? in
            guard case let .assistant(message) = item, message.turn.hasHydratedWorkedDetails else { return nil }
            return message.id
          })
        for index in page.conversation.indices {
          guard case let .assistant(message) = page.conversation[index],
            let itemID = message.turn.deferredDetailItemId,
            message.turn.isGenerating || hydratedIDs.contains(message.id)
          else { continue }
          let details = try await transport.transcriptDetails(itemId: itemID)
          page.conversation[index] = .assistant(
            AssistantMessage(
              id: message.id, turn: Self.hydratedTranscriptTurn(message, events: transport.detailEvents(from: details)))
          )
        }
      }
      try Task.checkCancellation()
      // Keep already loaded older pages (and their pagination cursor).
      let prefix =
        preservingContent
        ? page.conversation.first.flatMap { first in
          conversation.firstIndex(where: { $0.id == first.id }).map { Array(conversation.prefix($0)) }
        } : nil
      if prefix == nil {
        olderHistoryCursor = page.nextBefore
        hasOlderHistory = page.hasMore
      }
      setConversation((prefix ?? []) + page.conversation)
      if let persistedUsage = page.usage {
        usage = persistedUsage
      }
      persistedSetupPhases = page.setupPhases
      for update in page.stateUpdates {
        if case let .configOptionUpdate(saved) = update, !configOptions.isEmpty {
          configOptions = configOptions.map { current in
            guard let selection = saved.first(where: { $0.id == current.id }),
              current.options.contains(where: { $0.value == selection.currentValue })
            else { return current }
            var restored = current
            restored.currentValue = selection.currentValue
            return restored
          }
        } else {
          apply(.update(update))
        }
      }
      pendingQuestion = page.pendingQuestion
      pendingPlanApproval = page.pendingPlanApproval
      // The page is authoritative for the update gate: a `waiting` event
      // whose `released` this client never received (the server restarted
      // in between) must not keep the chat marked as held.
      updateGateHarnessName = page.updateGateHarnessName
      if let tasks = page.backgroundTasks {
        backgroundTasks = tasks
        hasBackgroundTaskSnapshot = true
      }
      goal = page.goal
      // The page and cursor form one durable session snapshot. Seed the
      // latest full checklist before subscribing after that cursor so a
      // plan event can never be skipped on reopen or another device.
      sessionPlan = page.sessionPlan
      isSending = lastTurnIsGenerating
      if isSending { noteProviderActivity(.modelStream) }
      serverEventCursor = page.eventCursor
      if preservingContent { applySynchronization(.catchingUp) }
      await startConsumer()
      restoreActiveTranscriptDetails()
      if defersPromptQueue {
        schedulePromptQueueLoad()
      } else {
        await loadPromptQueue(ifUnchangedSince: promptQueueRevision)
      }
      return .loaded
    } catch {
      // A cancelled load is the view going away (pane re-hosted, tab
      // switched), not a failure — the remounted view reloads history
      // itself. Surfacing it painted "cancelled" errors into every chat
      // whenever the workspace layout churned during a reload.
      return historyLoadOutcome(for: error)
    }

  }

  /// Whether the live stream has already carried this model strictly past a
  /// snapshot taken at `cursor`. True only for a model that has applied
  /// live events (its resume cursor is set) and whose cursor is beyond the
  /// snapshot's. A fresh model, a legacy stream, or a snapshot at or after
  /// the applied cursor all still load normally — an equal-cursor snapshot
  /// carries the same text, and it is also how a server-side repair that
  /// produced no event (a stuck row marked finished) reaches the client.
  func appliedStateIsCurrent(through cursor: Int) -> Bool {
    guard let applied = serverEventCursor,
      applied < ServerSessionTransport.liveOnlyEventCursor,
      hasActiveItem || !settledConversation.isEmpty
    else { return false }
    return applied > cursor
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
      let page = try await transport.completeHistoryPage(
        transport.transcriptPage(before: cursor, limit: Self.olderTranscriptPageSize),
        before: cursor, limit: Self.olderTranscriptPageSize)
      try Task.checkCancellation()
      let existing = Set(conversation.map(\.id))
      let unique = page.conversation
        .map(restoringCachedTranscriptDetails)
        .filter {
          $0.hasRenderableTranscriptContent && !existing.contains($0.id)
        }
      settledConversation.insert(contentsOf: unique, at: 0)
      rebuildSettledIndex()
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
