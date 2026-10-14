import Foundation
import ACPKit

extension SessionModel {
  private func apply(_ update: SessionUpdate) {
    appliedUpdateCount += 1
    if let owner = Self.persistedOwner(of: update), activeItem?.id != owner, settledIndexById[owner] == nil {
      return
    }
    if case let .plan(plan) = update {
      sessionPlan = plan
    }
    switch update {
    case let .userMessageChunk(block, _):
      appendRemoteUserIfNeeded(text: block.textValue ?? "")
    case let .availableCommandsUpdate(commands):
      availableCommands = commands
    case let .availableSkillsUpdate(skills):
      availableSkills = skills
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
        configOptions = preservingInFlightPicks(options)
      }
    case let .usageUpdate(usage):
      self.usage = usage
    case let .goalUpdate(goal):
      self.goal = goal
    case .goalCleared:
      goal = nil
    case let .question(request):
      pendingQuestion = request
    case let .questionResolved(resolution):
      if pendingQuestion?.questionId == resolution.questionId {
        pendingQuestion = nil
      }
      markActivePlanResumedIfNeeded()
      if resolution.outcome == .answered {
        ensureAssistantTurn()
        guard case .assistant(var message) = activeItem else { return }
        TranscriptReducer.apply(update, to: &message.turn)
        activeItem = .assistant(message)
        recordToolRoute(for: update, itemId: message.id)
      }
    default:
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
      if message.turn.retryStatus != nil { message.turn.retryStatus = nil }
      if !isSending { isSending = true }
      let planRevision = message.turn.planRevision
      let planDocument = message.turn.planDocument
      TranscriptReducer.apply(update, to: &message.turn)
      if case .planDocument = update,
        message.turn.planRevision != planRevision || message.turn.planDocument != planDocument
      {
        message.turn.planProposedAt = now()
        message.turn.planResumedAt = nil
      }
      activeItem = .assistant(message)
      recordToolRoute(for: update, itemId: message.id)
    }
  }

  private static func persistedOwner(of update: SessionUpdate) -> UUID? {
    switch update {
    case let .agentMessagePatch(patch): return patch.chatItemId.flatMap(UUID.init(uuidString:))
    case let .toolCall(call): return call.chatItemId.flatMap(UUID.init(uuidString:))
    default: return nil
    }
  }

  private func owningItemIndex(for update: SessionUpdate) -> Int? {
    if let owner = Self.persistedOwner(of: update) {
      return activeItem?.id == owner ? settledConversation.count : settledIndexById[owner]
    }
    var parentId: String?
    var toolCallId: String?
    switch update {
    case let .agentMessagePatch(patch):
      parentId = patch.parentToolCallId
    case let .agentMessageChunk(_, _, parent, _):
      parentId = parent
    case let .agentThoughtChunk(_, _, parent):
      parentId = parent
    case let .toolCall(call):
      parentId = call.parentToolCallId
      toolCallId = call.toolCallId
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
    if toolOwnerItemIds.count > 1024 {
      let resident = Set(
        conversation.flatMap { item -> [String] in
          guard case let .assistant(message) = item else { return [] }
          return message.turn.allToolCalls.map(\.toolCallId)
        })
      toolOwnerItemIds = toolOwnerItemIds.filter { resident.contains($0.key) }
    }
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
    if case let .synchronization(state) = event {
      applySynchronization(state)
      return
    }
    if !isReplayingHistory, connectionRecoveryTask != nil, streamSynchronization != .reconnecting {
      stopConnectionRecovery()
    }
    if !isReplayingHistory, isProviderActivity(event) {
      noteProviderActivity()
    }
    switch event {
    case .synchronization:
      break
    case let .update(update):
      apply(update)
    case let .assistantItemStarted(itemId):
      ensureAssistantTurn()
      adoptActiveAssistantItemIdentity(itemId)
      markActiveTurnStartedIfNeeded()
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
    case let .finished(stopReason, stopDetail, stopKind, retryable, chatItemId):
      let activeTurnContinues = finish(
        stopReason: stopReason,
        outcome: stopReason == .cancelled ? .cancelled : .completed,
        stopDetail: stopDetail,
        stopKind: stopKind,
        retryable: retryable,
        chatItemId: chatItemId
      )
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
      if !activeTurnContinues { endTurn() }
    case let .authenticationRequired(message):
      errorMessage = message
      harnessAuthenticationErrorMessage = message
      finish(stopReason: nil, outcome: .failed, stopDetail: message)
      endTurn()
    case let .retrying(retry):
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
    case .runtimeState:
      break
    case let .planApprovalRequired(required):
      pendingPlanApproval = required
      onPlanApprovalChanged?(required)
    case let .modelFallback(fallback):
      modelFallback = fallback
    }
  }

  public func clearModelFallback() {
    modelFallback = nil
  }

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
      if case let .assistant(active) = activeItem, active.turn.isGenerating {
        return true
      }
      pendingQuestion = nil
      return false
    }
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
    turn.stopDetail = stopDetail
    turn.stopKind = stopKind
    turn.retryable = retryable
    turn.endedAt = now()
    TranscriptReducer.settleToolCalls(&turn, outcome: outcome)
  }

  func endTurn() {
    let wasSending = isSending
    isSending = false
    stopConnectionRecovery()
    stalledTurnSchedule?.cancel()
    stalledTurnSchedule = nil
    isTakingLongerThanExpected = false
    if wasSending { onTurnEnded?() }
  }

  func noteProviderActivity() {
    if isTakingLongerThanExpected { isTakingLongerThanExpected = false }
    stalledTurnSchedule?.cancel()
    stalledTurnSchedule = quietTurnScheduler.schedule(Self.stalledTurnQuietInterval) { [weak self] in
      guard let self, self.isSending else { return }
      self.isTakingLongerThanExpected = true
      let cursorBeforeReload = self.serverEventCursor
      await self.reconcileFromServer()
      guard self.isSending else { return }
      let advanced: Bool
      if let before = cursorBeforeReload, let after = self.serverEventCursor {
        advanced = after > before
      } else {
        advanced = false
      }
      if !advanced { self.isTakingLongerThanExpected = true }
    }
  }

  private func isProviderActivity(_ event: ServerSessionStreamEvent) -> Bool {
    switch event {
    case let .update(update):
      switch update {
      case .agentMessagePatch, .agentMessageChunk, .agentThoughtChunk, .plan, .planDocument,
        .toolCall, .toolCallUpdate, .question, .questionResolved, .contextCompaction:
        return true
      case .userMessageChunk, .availableCommandsUpdate, .availableSkillsUpdate, .currentModeUpdate,
        .configOptionUpdate, .usageUpdate, .goalUpdate, .goalCleared:
        return false
      }
    case .retrying, .userMessage, .assistantItemStarted, .assistantFinalized:
      return true
    case .synchronization, .finished, .failed, .authenticationRequired, .queueUpdated, .updateGate,
      .backgroundTasks, .runtimeState, .planApprovalRequired, .modelFallback:
      return false
    }
  }

  private func appendRemoteUserIfNeeded(
    id: String? = nil,
    text: String,
    attachments: [Attachment] = []
  ) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || !attachments.isEmpty else { return }
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
  }

  private func rememberRemovedQueueItems(in updatedQueue: [ServerPromptQueueItem]) {
    let now = ProcessInfo.processInfo.systemUptime
    pendingQueuePromotionIDs = pendingQueuePromotionIDs.filter { $0.value > now }
    let updatedIDs = Set(updatedQueue.map(\.id))
    for item in queuedPrompts where !updatedIDs.contains(item.id) {
      pendingQueuePromotionIDs[item.id] = now + 5
    }
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
    pendingOptimisticUserMessageIDs.removeAll()
    if case let .assistant(message) = activeItem {
      if message.turn.isGenerating { return }
    }
    settleActiveItem()
    startActiveBubble()
    if !isSending { isSending = true }
  }

  func markActivePlanResumedIfNeeded() {
    guard case .assistant(var message) = activeItem,
      message.turn.isGenerating,
      message.turn.planProposedAt != nil,
      message.turn.planResumedAt == nil
    else { return }
    message.turn.planResumedAt = now()
    activeItem = .assistant(message)
  }

  func markActiveTurnStartedIfNeeded() {
    guard case .assistant(var message) = activeItem, message.turn.startedAt == nil else { return }
    message.turn.startedAt = now()
    activeItem = .assistant(message)
  }
}
