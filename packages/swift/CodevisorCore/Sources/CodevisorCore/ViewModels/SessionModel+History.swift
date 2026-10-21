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

  func loadHistoryForInitialDisplay(preloaded: TranscriptHistoryPage? = nil) async {
    surfaceHistoryLoadFailure(
      await loadHistoryOnce(preloaded: preloaded, defersPromptQueue: true)
    )
  }

  func loadHistoryReplacingCachedDisplay(preloaded: TranscriptHistoryPage?) async {
    surfaceHistoryLoadFailure(
      await loadHistoryOnce(preloaded: preloaded, defersPromptQueue: true, preservingContent: true)
    )
  }

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
          let (_, events) = try await transport.transcriptDetailEvents(itemId: itemID)
          page.conversation[index] = .assistant(
            AssistantMessage(id: message.id, turn: Self.hydratedTranscriptTurn(message, events: events))
          )
        }
      }
      try Task.checkCancellation()
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
      if let skills = page.skills {
        availableSkills = skills
      }
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
      if let pending = page.pendingQuestion, TranscriptSetupRequest.kind(of: pending.questions) != nil {
        applySetupUpdate(.question(pending), questionId: pending.questionId)
      }
      pendingPlanApproval = page.pendingPlanApproval
      updateGateHarnessName = page.updateGateHarnessName
      autoResume = page.autoResume
      if let tasks = page.backgroundTasks { backgroundTasks = tasks }
      goal = page.goal
      sessionPlan = page.sessionPlan
      isSending = lastTurnIsGenerating
      if isSending { noteProviderActivity() }
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
      return historyLoadOutcome(for: error)
    }

  }

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
      Log.session.error(
        "Failed to load prompt queue: \(String(describing: error), privacy: .public)"
      )
      guard revision == promptQueueRevision else { return }
      queuedPrompts = []
      promptQueueRevision &+= 1
    }
  }

  @discardableResult
  public func loadOlderHistory() async -> Int {
    guard usesPaginatedHistory, !isLoadingOlderHistory else { return 0 }
    isLoadingOlderHistory = true
    defer { isLoadingOlderHistory = false }
    do {
      while hasOlderHistory, let cursor = olderHistoryCursor {
        let anchor = conversation.first?.id
        let page = try await transport.completeHistoryPage(
          transport.transcriptPage(before: cursor, limit: Self.olderTranscriptPageSize),
          before: cursor, limit: Self.olderTranscriptPageSize)
        try Task.checkCancellation()
        guard olderHistoryCursor == cursor, conversation.first?.id == anchor else { continue }
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
      }
      return 0
    } catch {
      if !isTaskCancellation(error) {
        errorMessage = serverErrorMessage(error)
      }
      return 0
    }
  }

  private var lastTurnIsGenerating: Bool {
    if case let .assistant(message) = activeItem {
      if message.turn.isGenerating { return true }
    }
    return settledConversation.reversed().contains { item in
      if case let .assistant(message) = item { return message.turn.isGenerating }
      return false
    }
  }
}
