import Foundation
import ACPKit

extension SessionModel {
  /// Reopening an active turn restores its latest work without delaying the
  /// snapshot or live stream. No disclosure gesture is needed for a live turn.
  func restoreActiveTranscriptDetails() {
    for item in conversation {
      guard case let .assistant(message) = item,
        message.turn.isGenerating, !message.turn.hasHydratedWorkedDetails,
        let itemId = message.turn.deferredDetailItemId
      else { continue }
      _ = startTranscriptDetailLoad(itemId: itemId, previous: false)
    }
  }

  public func requestTranscriptDetailPage(_ request: TranscriptDetailPageRequest) -> Bool {
    guard transcriptDetailLoadTasks[request.itemID] == nil,
      let location = transcriptItemLocation(request.itemID),
      case let .assistant(message) = location.item,
      request.cursor == (request.previous ? message.turn.detailPreviousBefore : message.turn.detailNextAfter)
    else { return false }
    _ = startTranscriptDetailLoad(itemId: request.itemID, previous: request.previous)
    return true
  }

  /// Hydrates one historical assistant turn on demand. Only the bounded
  /// turn-scoped events are reduced; opening a disclosure never touches the
  /// rest of the session history.
  @discardableResult
  public func loadTranscriptDetails(itemId: String, previous: Bool = false) async -> Bool {
    if !previous && restoreTranscriptDetailsIfCached(itemId: itemId) { return true }
    return await startTranscriptDetailLoad(itemId: itemId, previous: previous).value
  }

  private func startTranscriptDetailLoad(itemId: String, previous: Bool) -> Task<Bool, Never> {
    if let task = transcriptDetailLoadTasks[itemId] {
      return task
    }
    loadingTranscriptDetailItemIds.insert(itemId)
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      defer {
        self.transcriptDetailLoadTasks.removeValue(forKey: itemId)
        self.loadingTranscriptDetailItemIds.remove(itemId)
      }
      return await self.fetchTranscriptDetails(itemId: itemId, previous: previous)
    }
    transcriptDetailLoadTasks[itemId] = task
    return task
  }

  private func fetchTranscriptDetails(itemId: String, previous: Bool) async -> Bool {
    guard let location = transcriptItemLocation(itemId), case let .assistant(message) = location.item else {
      return false
    }
    let initial = !message.turn.hasHydratedWorkedDetails
    let after =
      initial && message.turn.isGenerating
      ? "latest" : (previous ? message.turn.detailPreviousBefore : message.turn.detailNextAfter)
    do {
      let page = try await transport.transcriptDetails(itemId: itemId, after: after)
      try Task.checkCancellation()
      guard let location = transcriptItemLocation(itemId), case let .assistant(original) = location.item else {
        return false
      }
      var window = initial ? TranscriptDetailWindow() : (transcriptDetailWindows[itemId] ?? TranscriptDetailWindow())
      let resident = window.install(page, previous: previous)
      transcriptDetailWindows[itemId] = window
      var base = original
      // Adjacent pages overlap in memory so native scrolling retains its anchor.
      // Live updates newer than these snapshots must survive their installation.
      base.turn.detailAnswerPreview = original.turn.detailAnswerPreview ?? original.turn.finalText
      base.turn.entries = original.turn.entries.filter {
        original.turn.revision(of: $0, parent: nil) > resident.eventCursor
      }
      base.turn.subagents = original.turn.subagents.reduce(into: [:]) { result, pair in
        let (parent, bucket) = pair
        var kept = bucket
        kept.entries = bucket.entries.filter { entry in
          original.turn.revision(of: entry, parent: parent) > resident.eventCursor
        }
        if !kept.entries.isEmpty { result[parent] = kept }
      }
      var turn = Self.hydratedTranscriptTurn(base, events: transport.detailEvents(from: resident))
      turn.detailAnswerPreview = original.turn.detailAnswerPreview ?? original.turn.finalText
      if case let .text(id, _) = turn.detailAnswerPreview, let phase = original.turn.textPhases[id] {
        turn.textPhases[id] = phase
      }
      turn.detailNextAfter = resident.nextAfter
      turn.detailPreviousBefore = resident.previousBefore
      turn.detailPageCursor = after
      turn.hasDeferredWorkedDetails = resident.nextAfter != nil || resident.previousBefore != nil
      turn.deferredDetailItemId = itemId
      turn.detailRevision = page.revision
      turn.pruneEntryMetadata()
      let hydrated = ConversationItem.assistant(AssistantMessage(id: original.id, turn: turn))
      if page.nextAfter == nil && page.previousBefore == nil && !turn.isGenerating {
        transcriptDetailsCache[itemId] = TranscriptDetailsCacheEntry(revision: page.revision, turn: turn)
        if transcriptDetailsCache.count > 8, let oldest = transcriptDetailsCache.keys.first(where: { $0 != itemId }) {
          transcriptDetailsCache.removeValue(forKey: oldest)
        }
      }
      installTranscriptDetails(hydrated, at: location.storage)
      retainDetailWindow(itemId: itemId)
      return true
    } catch {
      if !isTaskCancellation(error) { errorMessage = serverErrorMessage(error) }
      return false
    }
  }

  private static func hydratedTranscriptTurn(
    _ originalMessage: AssistantMessage,
    events: [ServerSessionStreamEvent]
  ) -> AssistantTurn {
    var turn = originalMessage.turn
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
      case let .finished(reason, detail, stopKind, retryable, _, _):
        turn.stopReason = reason
        turn.stopDetail = detail
        turn.stopKind = stopKind
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
      case .synchronization, .userMessage, .queueUpdated, .retrying, .backgroundTasks, .runtimeState,
        .planApprovalRequired, .updateGate, .modelFallback:
        break
      }
    }
    turn.isGenerating = originalMessage.turn.isGenerating
    turn.startedAt = originalMessage.turn.startedAt
    turn.endedAt = originalMessage.turn.endedAt
    turn.stopReason = originalMessage.turn.stopReason
    turn.stopDetail = originalMessage.turn.stopDetail
    turn.stopKind = originalMessage.turn.stopKind
    turn.retryable = originalMessage.turn.retryable
    turn.planDocument = turn.planDocument ?? originalMessage.turn.planDocument
    if turn.attachments.isEmpty { turn.attachments = originalMessage.turn.attachments }
    turn.deferredDetailItemId = nil
    turn.hasDeferredWorkedDetails = false
    turn.detailRevision = originalMessage.turn.detailRevision
    turn.hasHydratedWorkedDetails = true
    return turn
  }

  private func restoreTranscriptDetailsIfCached(itemId: String) -> Bool {
    guard let cached = transcriptDetailsCache[itemId] else { return false }
    // A row task can briefly outlive the deferred row it hydrated. The
    // cache entry proves that work already completed successfully.
    guard let location = transcriptItemLocation(itemId) else { return true }
    guard case let .assistant(originalMessage) = location.item,
      !originalMessage.turn.hasDeferredWorkedDetails,
      cached.revision == originalMessage.turn.detailRevision
    else { return false }
    let hydrated = ConversationItem.assistant(
      AssistantMessage(id: originalMessage.id, turn: cached.turn)
    )
    installTranscriptDetails(hydrated, at: location.storage)
    return true
  }

  private func installTranscriptDetails(
    _ item: ConversationItem,
    at location: TranscriptStorageLocation
  ) {
    switch location {
    case let .settled(index): settledConversation[index] = item
    case .active: activeItem = item
    }
    guard case let .assistant(message) = item else { return }
    for call in message.turn.allToolCalls {
      toolOwnerItemIds[call.toolCallId] = message.id
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

}
