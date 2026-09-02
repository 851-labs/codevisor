import Foundation
import ACPKit

extension SessionModel {
  // MARK: - Settled/active storage

  /// The active slot remains mounted after completion for stable rendering.
  /// It becomes receipt-eligible only once the assistant turn has stopped.
  var activeFinishedResponseItemId: UUID? {
    guard case let .assistant(message)? = activeItem,
      !message.turn.isGenerating
    else { return nil }
    return message.id
  }

  /// Moves the active bubble into the settled list. Called only at bubble
  /// boundaries, so `settledConversation` (and the boundary-guarded
  /// `hasActiveItem`) never change on a token flush.
  func settleActiveItem() {
    guard let item = activeItem else { return }
    appendSettled(item)
    activeItem = nil
    hasActiveItem = false
  }

  func appendSettled(_ item: ConversationItem) {
    guard item.hasRenderableTranscriptContent else { return }
    settledIndexById[item.id] = settledConversation.count
    settledConversation.append(item)
  }

  func rebuildSettledIndex() {
    settledIndexById = Dictionary(
      uniqueKeysWithValues: settledConversation.enumerated().map { ($0.element.id, $0.offset) }
    )
  }

  /// Starts a fresh generating assistant bubble as the active item.
  func startActiveBubble() {
    stopConnectionRecovery()
    // A new turn (user- or agent-initiated) clears any lingering session-
    // level error banner so it can't outlive the failure it described —
    // including a stale one replayed from history on reconnect.
    errorMessage = nil
    harnessAuthenticationErrorMessage = nil
    activeItem = .assistant(
      AssistantMessage(
        // Waiting for the first provider event is not itself reasoning.
        // Explicit thought chunks flip this to true in TranscriptReducer.
        turn: AssistantTurn(isGenerating: true, isThinking: false, startedAt: now())
      ))
    if !hasActiveItem { hasActiveItem = true }
  }

  /// Reconciles the optimistic/live bubble with the canonical semantic item
  /// created by the server for this turn. Tool ownership is re-keyed too so
  /// late background updates continue routing into the same settled bubble.
  func adoptActiveAssistantItemIdentity(_ id: UUID) {
    guard case let .assistant(message) = activeItem, message.id != id else { return }
    let previousId = message.id
    activeItem = .assistant(AssistantMessage(id: id, turn: message.turn))
    let ownedRoutes = toolOwnerItemIds.compactMap { route, owner in
      owner == previousId ? route : nil
    }
    for route in ownedRoutes {
      toolOwnerItemIds[route] = id
    }
  }

  /// Replaces conversation state wholesale (history load, previews). The
  /// trailing assistant bubble stays active so live streaming resumes into
  /// the same storage slot the transcript's active row renders.
  func setConversation(_ items: [ConversationItem]) {
    // A canonical snapshot supersedes any locally inferred echo state.
    // Events after its cursor carry enough identity to reconcile normally.
    pendingOptimisticUserMessageIDs.removeAll()
    let items =
      items
      .map(restoringCachedTranscriptDetails)
      .filter(\.hasRenderableTranscriptContent)
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
  func item(at index: Int) -> ConversationItem? {
    if index < settledConversation.count { return settledConversation[index] }
    if index == settledConversation.count { return activeItem }
    return nil
  }

  func setItem(_ item: ConversationItem, at index: Int) {
    if index < settledConversation.count {
      settledConversation[index] = item
    } else if index == settledConversation.count, activeItem != nil {
      activeItem = item
    }
  }

  /// Reuses hydrated details before publishing a replacement history page,
  /// so the UI never projects a deferred loading row for cached content.
  func restoringCachedTranscriptDetails(_ item: ConversationItem) -> ConversationItem {
    guard case let .assistant(message) = item,
      let itemId = message.turn.deferredDetailItemId,
      let cached = transcriptDetailsCache[itemId],
      cached.revision == message.turn.detailRevision
    else { return item }
    return .assistant(AssistantMessage(id: message.id, turn: cached.turn))
  }

  var itemCount: Int {
    settledConversation.count + (activeItem == nil ? 0 : 1)
  }

  /// Seeds conversation state for previews. Not for production use.
  public func applyPreviewState(conversation: [ConversationItem], isSending: Bool, usage: SessionUsage? = nil) {
    setConversation(conversation)
    self.isSending = isSending
    self.usage = usage
  }
}
