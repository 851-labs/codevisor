import Foundation
import ACPKit

extension SessionModel {
  func apply(_ event: ServerSessionStreamEvent) {
    if case let .synchronization(state) = event {
      applySynchronization(state)
      return
    }
    if liveEventEndsRecovery { connectionRecovery.stop() }
    if isLiveProviderActivity(event) { noteProviderActivity() }

    dispatch(event)
  }

  public func clearModelFallback() {
    modelFallback = nil
  }

  @discardableResult
  func finish(_ stop: SessionTurnStop, chatItemId: UUID? = nil) -> Bool {
    guard closeSettledTurn(chatItemId, stop) else {
      pendingQuestion = nil
      closeActiveTurn(stop)
      return false
    }
    guard !activeTurnIsGenerating else { return true }

    pendingQuestion = nil
    return false
  }

  func endTurn() {
    let wasSending = isSending
    isSending = false
    connectionRecovery.stop()
    stalledTurnWatch.stop()
    isTakingLongerThanExpected = false
    if wasSending { onTurnEnded?() }
  }

  func noteProviderActivity() {
    if isTakingLongerThanExpected { isTakingLongerThanExpected = false }
    stalledTurnWatch.restart(for: self)
  }

  func applySetupUpdate(_ update: SessionUpdate, questionId: String) {
    guard let owner = setupOwnerIndex(questionId: questionId),
      case .assistant(var message) = item(at: owner)
    else { return }

    TranscriptReducer.apply(update, to: &message.turn)
    setItem(.assistant(message), at: owner)
    transcriptProjectionRevision &+= 1
  }

  func selectMode(_ modeId: String) {
    guard var state = modeState else { return }

    state.currentModeId = modeId
    modeState = state
  }

  private var liveEventEndsRecovery: Bool {
    !isReplayingHistory && connectionRecovery.isRunning && streamSynchronization != .reconnecting
  }

  private func isLiveProviderActivity(_ event: ServerSessionStreamEvent) -> Bool {
    !isReplayingHistory && SessionStalledTurnWatch.isProviderActivity(event)
  }

  private func dispatch(_ event: ServerSessionStreamEvent) {
    switch event {
    case .synchronization, .runtimeState:
      break
    case let .update(update):
      apply(update)
    case let .assistantItemStarted(itemId):
      startAssistantItem(itemId)
    case let .assistantFinalized(markdown, messageId, attachments):
      finalizeAssistant(markdown: markdown, messageId: messageId, attachments: attachments)
    case let .userMessage(id, text, attachments, isEvent, assistantItemId):
      let remote = RemoteUserMessage(
        id: id, text: text, attachments: attachments, isEvent: isEvent, assistantItemId: assistantItemId)
      applyUserMessage(remote)
    case let .finished(stopReason, stopDetail, stopKind, retryable, chatItemId):
      let stop = SessionTurnStop.finished(stopReason, detail: stopDetail, kind: stopKind, retryable: retryable)
      finishTurn(stop, chatItemId: chatItemId)
    case let .failed(message, retryable, chatItemId):
      applyFailure(message, retryable: retryable, chatItemId: chatItemId)
    case let .authenticationRequired(message):
      requireAuthentication(message)
    case let .retrying(retry):
      showRetry(retry)
    case let .queueUpdated(queue):
      promptQueue.apply(queue)
    case let .updateGate(waiting, harnessName):
      updateGateHarnessName = waiting ? harnessName : nil
    case let .autoResume(pending):
      autoResume = pending
    case let .backgroundTasks(tasks):
      backgroundTasks = tasks
    case let .planApprovalRequired(required):
      requirePlanApproval(required)
    case let .modelFallback(fallback):
      modelFallback = fallback
    case let .botMessage(message):
      upsertBotMessage(message)
    }
  }

  private func startAssistantItem(_ itemId: UUID) {
    ensureAssistantTurn()
    adoptActiveAssistantItemIdentity(itemId)
    markActiveTurnStartedIfNeeded()
  }

  private func finalizeAssistant(markdown: String, messageId: String?, attachments: [Attachment]) {
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
  }

  private func applyUserMessage(_ remote: RemoteUserMessage) {
    appliedUpdateCount += 1
    let promotedFromQueue = promptQueue.consumePromotion(id: remote.id)
    appendRemoteUserIfNeeded(remote)

    if let echoId = remote.echoId { confirmOutgoing(echoId) }
    if promotedFromQueue, !remote.isEvent { onQueuedPromptPromoted?(remote.echoId) }
  }

  private func finishTurn(_ stop: SessionTurnStop, chatItemId: UUID?) {
    let activeTurnContinues = finish(stop, chatItemId: chatItemId)
    if !activeTurnContinues { endTurn() }
  }

  private func applyFailure(_ message: String, retryable: Bool, chatItemId: UUID?) {
    errorMessage = message
    finishTurn(.failed(message, retryable: retryable), chatItemId: chatItemId)
  }

  private func requireAuthentication(_ message: String) {
    errorMessage = message
    harnessAuthenticationErrorMessage = message
    finish(.failed(message))
    endTurn()
  }

  private func showRetry(_ retry: RetryStatus) {
    ensureAssistantTurn()
    guard case .assistant(var message) = activeItem else { return }

    message.turn.isGenerating = true
    message.turn.retryStatus = retry
    activeItem = .assistant(message)
    markSending()
  }

  private func requirePlanApproval(_ required: Bool) {
    pendingPlanApproval = required
    onPlanApprovalChanged?(required)
  }

  private func closeSettledTurn(_ chatItemId: UUID?, _ stop: SessionTurnStop) -> Bool {
    guard let chatItemId,
      activeItem?.id != chatItemId,
      let index = settledIndexById[chatItemId],
      case .assistant(var settled) = settledConversation[index]
    else { return false }

    stop.close(&settled.turn, endedAt: now())
    settledConversation[index] = .assistant(settled)
    return true
  }

  private func closeActiveTurn(_ stop: SessionTurnStop) {
    guard case .assistant(var message) = activeItem else { return }

    stop.close(&message.turn, endedAt: now())
    activeItem = .assistant(message)
  }

  private func apply(_ update: SessionUpdate) {
    appliedUpdateCount += 1
    guard !belongsToUnloadedItem(update) else { return }

    if case let .plan(plan) = update { sessionPlan = plan }
    dispatch(update)
  }

  private func dispatch(_ update: SessionUpdate) {
    switch update {
    case let .userMessageChunk(block, _):
      appendRemoteUserIfNeeded(RemoteUserMessage(text: block.textValue ?? ""))
    case let .availableCommandsUpdate(commands):
      availableCommands = commands
    case let .availableSkillsUpdate(skills):
      availableSkills = skills
    case let .currentModeUpdate(modeId):
      selectMode(modeId)
    case let .configOptionUpdate(options):
      applyConfigOptions(options)
    case let .usageUpdate(usage):
      self.usage = usage
    case let .goalUpdate(goal):
      self.goal = goal
    case .goalCleared:
      goal = nil
    case let .question(request):
      applyQuestion(request)
    case let .questionResolved(resolution):
      applyQuestionResolution(resolution)
    default:
      applyTranscriptUpdate(update)
    }
  }

  private func belongsToUnloadedItem(_ update: SessionUpdate) -> Bool {
    guard let owner = SessionUpdateRoutes.persistedOwner(of: update) else { return false }
    return itemIndex(of: owner) == nil
  }

  private func applyConfigOptions(_ options: [SessionConfigOption]) {
    guard isReplayingHistory else {
      configuration.adoptLive(options)
      return
    }

    for option in options {
      historicalConfigSelections[option.id] = option.currentValue
    }
  }

  private func applyQuestion(_ request: QuestionRequest) {
    pendingQuestion = request
    guard Self.isSetupQuestion(request.questions) else { return }

    applySetupUpdate(.question(request), questionId: request.questionId)
    closeActiveSection()
    settleActiveItem()
  }

  private func applyQuestionResolution(_ resolution: QuestionResolution) {
    if pendingQuestion?.questionId == resolution.questionId { pendingQuestion = nil }
    markActivePlanResumedIfNeeded()

    if Self.isSetupQuestion(resolution.questions) {
      resolveSetupQuestion(resolution)
    } else if resolution.outcome == .answered {
      applyAnswer(resolution)
    }
  }

  private func resolveSetupQuestion(_ resolution: QuestionResolution) {
    applySetupUpdate(.questionResolved(resolution), questionId: resolution.questionId)
    guard let continuation = resolution.assistantItemId.flatMap(UUID.init(uuidString:)),
      activeItem == nil
    else { return }

    startActiveBubble()
    adoptActiveAssistantItemIdentity(continuation)
    markSending()
  }

  private func applyAnswer(_ resolution: QuestionResolution) {
    let update = SessionUpdate.questionResolved(resolution)
    ensureAssistantTurn()
    guard case .assistant(var message) = activeItem else { return }

    TranscriptReducer.apply(update, to: &message.turn)
    activeItem = .assistant(message)
    updateRoutes.record(update, owner: message.id, conversation: conversation)
  }

  private func applyTranscriptUpdate(_ update: SessionUpdate) {
    if appliedToOwningItem(update) { return }

    applyToGeneratingTurn(update)
  }

  private func appliedToOwningItem(_ update: SessionUpdate) -> Bool {
    guard let index = owningItemIndex(for: update),
      case .assistant(var message) = item(at: index),
      !isGeneratingTail(message, at: index)
    else { return false }

    TranscriptReducer.apply(update, to: &message.turn)
    setItem(.assistant(message), at: index)
    updateRoutes.record(update, owner: message.id, conversation: conversation)
    transcriptDetails.loadDeferred(of: message)
    return true
  }

  private func applyToGeneratingTurn(_ update: SessionUpdate) {
    ensureAssistantTurn()
    guard case .assistant(var message) = activeItem else { return }

    message.turn.isGenerating = true
    if message.turn.retryStatus != nil { message.turn.retryStatus = nil }
    markSending()
    apply(update, stampingPlanProposalIn: &message.turn)
    activeItem = .assistant(message)
    updateRoutes.record(update, owner: message.id, conversation: conversation)
  }

  private func apply(_ update: SessionUpdate, stampingPlanProposalIn turn: inout AssistantTurn) {
    let planRevision = turn.planRevision
    let planDocument = turn.planDocument
    TranscriptReducer.apply(update, to: &turn)
    guard case .planDocument = update,
      Self.planChanged(turn, revision: planRevision, document: planDocument)
    else { return }

    turn.planProposedAt = now()
    turn.planResumedAt = nil
  }

  private func isGeneratingTail(_ message: AssistantMessage, at index: Int) -> Bool {
    index == itemCount - 1 && message.turn.isGenerating
  }

  private func owningItemIndex(for update: SessionUpdate) -> Int? {
    guard let ownerId = updateRoutes.owner(of: update) else { return nil }

    return itemIndex(of: ownerId)
  }

  private func itemIndex(of ownerId: UUID) -> Int? {
    if activeItem?.id == ownerId { return settledConversation.count }
    return settledIndexById[ownerId]
  }

  private func appendRemoteUserIfNeeded(_ remote: RemoteUserMessage) {
    guard remote.hasContent else { return }

    switch remote.match(in: settledConversation, pendingOptimisticIds: pendingOptimisticUserMessageIDs) {
    case let .echo(index, echoId):
      mergeRemoteEcho(remote, at: index)
      pendingOptimisticUserMessageIDs.remove(echoId)
    case let .optimistic(index, user):
      confirmOptimisticUser(user, at: index, from: remote)
    case nil:
      appendRemoteUser(remote)
    }
  }

  private func mergeRemoteEcho(_ remote: RemoteUserMessage, at index: Int) {
    guard case let .user(user) = settledConversation[index] else { return }

    let merged = ConversationItem.user(remote.mergingEcho(into: user))
    guard merged != settledConversation[index] else { return }

    settledConversation[index] = merged
  }

  private func confirmOptimisticUser(_ user: UserMessage, at index: Int, from remote: RemoteUserMessage) {
    if let filled = remote.fillingAttachments(of: user) { settledConversation[index] = .user(filled) }
    pendingOptimisticUserMessageIDs.remove(user.id)
  }

  private func appendRemoteUser(_ remote: RemoteUserMessage) {
    closeActiveSection()
    settleActiveItem()
    appendSettled(.user(remote.userMessage))
    startActiveBubble()
    if let assistantItemId = remote.assistantItemId { adoptActiveAssistantItemIdentity(assistantItemId) }
    markSending()
  }

  private func closeActiveSection() {
    guard case var .assistant(message) = activeItem, message.turn.isGenerating else { return }

    message.turn.isGenerating = false
    message.turn.isThinking = false
    message.turn.retryStatus = nil
    message.turn.endedAt = now()
    activeItem = .assistant(message)
  }

  private func setupOwnerIndex(questionId: String) -> Int? {
    let indices = (0..<itemCount).reversed()
    return indices.first { asksSetupQuestion(questionId, at: $0) } ?? indices.first { isAssistantItem(at: $0) }
  }

  private func asksSetupQuestion(_ questionId: String, at index: Int) -> Bool {
    guard case let .assistant(message) = item(at: index) else { return false }
    return message.turn.setupRequests.contains { $0.id == questionId }
  }

  private func isAssistantItem(at index: Int) -> Bool {
    guard case .assistant = item(at: index) else { return false }
    return true
  }

  private var activeTurnIsGenerating: Bool {
    guard case let .assistant(message) = activeItem else { return false }
    return message.turn.isGenerating
  }

  private func ensureAssistantTurn() {
    pendingOptimisticUserMessageIDs.removeAll()
    guard !activeTurnIsGenerating else { return }

    settleActiveItem()
    startActiveBubble()
    markSending()
  }

  private func markSending() {
    if !isSending { isSending = true }
  }

  private func markActivePlanResumedIfNeeded() {
    guard case .assistant(var message) = activeItem, Self.awaitsPlanResume(message.turn) else { return }

    message.turn.planResumedAt = now()
    activeItem = .assistant(message)
  }

  private func markActiveTurnStartedIfNeeded() {
    guard case .assistant(var message) = activeItem, message.turn.startedAt == nil else { return }

    message.turn.startedAt = now()
    activeItem = .assistant(message)
  }

  private nonisolated static func isSetupQuestion(_ questions: [QuestionSpec]) -> Bool {
    TranscriptSetupRequest.kind(of: questions) != nil
  }

  private nonisolated static func planChanged(_ turn: AssistantTurn, revision: Int, document: String?) -> Bool {
    turn.planRevision != revision || turn.planDocument != document
  }

  private nonisolated static func awaitsPlanResume(_ turn: AssistantTurn) -> Bool {
    turn.isGenerating && turn.planProposedAt != nil && turn.planResumedAt == nil
  }
}
