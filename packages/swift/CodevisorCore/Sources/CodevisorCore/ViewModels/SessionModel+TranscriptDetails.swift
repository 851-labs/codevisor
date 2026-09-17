import Foundation
import ACPKit

extension SessionModel {
  /// Restore active work without coupling its lifetime to a mounted disclosure.
  func restoreActiveTranscriptDetails() {
    for item in conversation {
      guard case let .assistant(message) = item,
        message.turn.isGenerating, !message.turn.hasHydratedWorkedDetails,
        let itemID = message.turn.deferredDetailItemId
      else { continue }
      _ = startTranscriptDetailLoad(itemId: itemID)
    }
  }

  /// Storage pages are assembled off-screen and installed once. Loaded work
  /// stays resident for this chat, exactly like the original disclosure contract.
  @discardableResult
  public func loadTranscriptDetails(itemId: String) async -> Bool {
    if restoreTranscriptDetailsIfCached(itemId: itemId) { return true }
    return await startTranscriptDetailLoad(itemId: itemId).value
  }

  private func startTranscriptDetailLoad(itemId: String) -> Task<Bool, Never> {
    if let task = transcriptDetailLoadTasks[itemId] { return task }
    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      defer { self.transcriptDetailLoadTasks.removeValue(forKey: itemId) }
      do {
        let details = try await self.transport.transcriptDetails(itemId: itemId)
        try Task.checkCancellation()
        guard let location = self.transcriptItemLocation(itemId),
          case let .assistant(original) = location.item
        else { return false }
        // Streamed revisions may have advanced while storage was loading.
        // The reducer merges snapshots by stable identity and revision.
        var turn = Self.hydratedTranscriptTurn(original, events: self.transport.detailEvents(from: details))
        turn.detailRevision = max(turn.detailRevision, details.revision)
        let hydrated = ConversationItem.assistant(AssistantMessage(id: original.id, turn: turn))
        if !turn.isGenerating {
          self.transcriptDetailsCache[itemId] = TranscriptDetailsCacheEntry(revision: details.revision, turn: turn)
        }
        self.installTranscriptDetails(hydrated, at: location.storage)
        return true
      } catch {
        if !isTaskCancellation(error) { self.errorMessage = serverErrorMessage(error) }
        return false
      }
    }
    transcriptDetailLoadTasks[itemId] = task
    return task
  }

  static func hydratedTranscriptTurn(
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
