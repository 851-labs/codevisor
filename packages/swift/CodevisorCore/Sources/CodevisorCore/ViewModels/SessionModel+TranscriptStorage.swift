import Foundation
import ACPKit

extension SessionModel {
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

  func startActiveBubble(startedAt: Date? = nil) {
    stopConnectionRecovery()
    errorMessage = nil
    harnessAuthenticationErrorMessage = nil
    activeItem = .assistant(
      AssistantMessage(
        turn: AssistantTurn(isGenerating: true, isThinking: false, startedAt: startedAt ?? now())
      ))
    if !hasActiveItem { hasActiveItem = true }
  }

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

  func setConversation(_ items: [ConversationItem]) {
    pendingOptimisticUserMessageIDs.removeAll()
    let items =
      items
      .map(restoringCachedTranscriptDetails)
      .map(carryingLiveTurnState)
      .filter(\.hasRenderableTranscriptContent)
    if case .assistant = items.last {
      settledConversation = Array(items.dropLast())
      activeItem = preservingLocalTurnStart(items.last)
      if !hasActiveItem { hasActiveItem = true }
    } else {
      settledConversation = items
      activeItem = nil
      if hasActiveItem { hasActiveItem = false }
    }
    rebuildSettledIndex()
  }

  func carryingLiveTurnState(_ incoming: ConversationItem) -> ConversationItem {
    guard case var .assistant(message) = incoming else { return incoming }
    let current: AssistantMessage? =
      if case let .assistant(active)? = activeItem, active.id == message.id {
        active
      } else if let index = settledIndexById[message.id], index < settledConversation.count,
        case let .assistant(settled) = settledConversation[index]
      {
        settled
      } else {
        nil
      }
    guard let current else { return incoming }
    var carried = false
    if !current.turn.callsAfterReasoning.isSubset(of: message.turn.callsAfterReasoning) {
      message.turn.callsAfterReasoning.formUnion(current.turn.callsAfterReasoning)
      carried = true
    }
    if let localStart = current.turn.startedAt, message.turn.startedAt.map({ localStart < $0 }) ?? true {
      message.turn.startedAt = localStart
      carried = true
    }
    let missingSetupRequests = current.turn.setupRequests.filter { request in
      !message.turn.setupRequests.contains { $0.id == request.id }
    }
    if !missingSetupRequests.isEmpty {
      message.turn.setupRequests += missingSetupRequests
      carried = true
    }
    return carried ? .assistant(message) : incoming
  }

  private func preservingLocalTurnStart(_ incoming: ConversationItem?) -> ConversationItem? {
    guard case let .assistant(incomingMessage)? = incoming,
      incomingMessage.turn.startedAt == nil,
      case let .assistant(current) = activeItem,
      current.id == incomingMessage.id,
      let localStart = current.turn.startedAt
    else { return incoming }
    var message = incomingMessage
    message.turn.startedAt = localStart
    return .assistant(message)
  }

  func item(at index: Int) -> ConversationItem? {
    if index < settledConversation.count { return settledConversation[index] }
    if index == settledConversation.count { return activeItem }
    return nil
  }

  func setItem(_ item: ConversationItem, at index: Int) {
    let item = carryingLiveTurnState(item)
    if index < settledConversation.count {
      settledConversation[index] = item
    } else if index == settledConversation.count, activeItem != nil {
      activeItem = item
    }
  }

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

  public func applyPreviewState(conversation: [ConversationItem], isSending: Bool, usage: SessionUsage? = nil) {
    setConversation(conversation)
    self.isSending = isSending
    self.usage = usage
  }
}
