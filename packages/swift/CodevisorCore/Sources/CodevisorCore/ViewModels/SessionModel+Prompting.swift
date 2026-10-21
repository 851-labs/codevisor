import Foundation
import ACPKit

extension SessionModel {
  public func send() async {
    await send(composerText)
  }

  public func send(_ text: String, attachments: [Attachment] = []) async {
    await send(UserMessage(text: text, attachments: attachments))
  }

  public func send(
    _ outgoingMessage: UserMessage,
    startedAt: Date? = nil,
    delivery: ServerPromptDelivery = .steer
  ) async {
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

    if presentsBotConversation {
      await sendOutgoing(message, delivery: nil)
      return
    }

    if isSending {
      await sendOutgoing(message, delivery: delivery)
      return
    }

    settleActiveItem()
    appendSettled(.user(message))
    pendingOptimisticUserMessageIDs.insert(message.id)
    startActiveBubble(startedAt: startedAt)
    isSending = true
    noteProviderActivity()
    onLocalUserMessageAppended?(message.id)

    await startConsumer()

    let actionID = message.id.uuidString.lowercased()
    unreachedSend = nil
    switch await deliver(message, delivery: nil, actionID: actionID) {
    case .accepted:
      slowMessageIDs.remove(message.id)
      onPromptAccepted?(message.attachments.count, false)
      await drain()
    case let .failed(error):
      slowMessageIDs.remove(message.id)
      unreachedSend = UnreachedSend(messageID: message.id, actionID: actionID)
      await drain()
      pendingOptimisticUserMessageIDs.remove(message.id)
      failTurn(serverErrorMessage(error))
    }
  }

  private func failTurn(_ detail: String) {
    errorMessage = detail
    finish(stopReason: nil, outcome: .failed, stopDetail: detail, retryable: true)
    endTurn()
  }

  public func retryResponse(to prompt: UserMessage) async {
    guard !isSending else { return }

    errorMessage = nil
    harnessAuthenticationErrorMessage = nil
    settleActiveItem()
    startActiveBubble()
    isSending = true
    noteProviderActivity()
    await startConsumer()

    let actionID =
      unreachedSend.flatMap { $0.messageID == prompt.id ? $0.actionID : nil } ?? UUID().uuidString.lowercased()
    switch await deliver(prompt, delivery: nil, actionID: actionID) {
    case .accepted:
      slowMessageIDs.remove(prompt.id)
      if unreachedSend?.messageID == prompt.id { unreachedSend = nil }
      await drain()
    case let .failed(error):
      slowMessageIDs.remove(prompt.id)
      unreachedSend = UnreachedSend(messageID: prompt.id, actionID: actionID)
      await drain()
      failTurn(serverErrorMessage(error))
    }
  }

  @discardableResult
  public func updateQueuedPrompt(id: String, text: String, attachments: [Attachment]? = nil) async -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty || attachments?.isEmpty == false else { return false }
    do {
      _ = try await transport.updateQueuedPrompt(id: id, text: trimmed, attachments: attachments)
      return true
    } catch {
      errorMessage = serverErrorMessage(error)
      return false
    }
  }

  @discardableResult
  public func reorderQueuedPrompts(ids: [String]) async -> Bool {
    guard ids.count == Set(ids).count else { return false }
    let previous = queuedPrompts
    applyQueuedPromptSnapshot(Self.queue(previous, orderedBy: ids))
    do {
      let queue = try await transport.reorderQueuedPrompts(ids: ids)
      applyQueuedPromptSnapshot(queue)
      return true
    } catch {
      applyQueuedPromptSnapshot(previous)
      errorMessage = serverErrorMessage(error)
      return false
    }
  }

  private static func queue(
    _ queue: [ServerPromptQueueItem], orderedBy ids: [String]
  ) -> [ServerPromptQueueItem] {
    let byID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })
    let ordered = ids.compactMap { byID[$0] }
    return ordered + queue.filter { !ids.contains($0.id) }
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

  @discardableResult
  public func sendQueuedPromptNow(id: String) async -> Bool {
    do {
      _ = try await transport.sendQueuedPromptNow(id: id)
      return true
    } catch CodevisorServerClientError.httpStatus(404, _) {
      return false
    } catch {
      errorMessage = serverErrorMessage(error)
      return false
    }
  }

  public func cancel() async {
    guard isSending, !isCancelling else { return }
    isCancelling = true
    noteProviderActivity()
    defer { isCancelling = false }
    do {
      try await transport.cancel()
    } catch {
      errorMessage = serverErrorMessage(error)
      return
    }

    for _ in 0..<20 {
      try? await Task.sleep(for: Self.cancellationTerminalEventWaitDelay)
      await flushPendingEventsAtPresentationBoundary()
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

  public func reconcileIfInFlight() async {
    guard isSending || isViewVisible else { return }
    await reconcileFromServer()
  }

  public func reconcileIfStalled() async {
    guard (isSending && isTakingLongerThanExpected) || streamSynchronization == .reconnecting else { return }
    await reconcileFromServer()
  }

  func reconcileFromServer() async {
    guard connectionRecoveryTask == nil else { return }
    connectionRecoveryGeneration &+= 1
    let generation = connectionRecoveryGeneration
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      var handedOffRetry = false
      defer {
        if !handedOffRetry, self.connectionRecoveryGeneration == generation { self.connectionRecoveryTask = nil }
      }
      let outcome = await self.performReconciliationAttempt()
      guard !Task.isCancelled else { return }
      switch outcome {
      case .loaded:
        self.completeConnectionRecovery()
      case .cancelled:
        break
      case let .failed(message, retryable):
        if retryable {
          handedOffRetry = true
          self.connectionRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
              if self.connectionRecoveryGeneration == generation { self.connectionRecoveryTask = nil }
            }
            await self.runConnectionRecovery()
          }
        } else {
          self.surfaceConnectionRecoveryFailure(message)
        }
      }
    }
    connectionRecoveryTask = task
    await task.value
  }

  private func performReconciliationAttempt() async -> SessionHistoryLoadOutcome {
    let wasSending = isSending
    consumerTask?.cancel()
    consumerTask = nil
    pendingEvents.invalidateConsumer()
    scheduledFlushTask?.cancel()
    scheduledFlushTask = nil
    isFlushScheduled = false
    let outcome = await loadHistoryForConnectionRecovery()
    guard case .loaded = outcome else {
      await startConsumer()
      return outcome
    }
    if wasSending, !isSending {
      stalledTurnSchedule?.cancel()
      stalledTurnSchedule = nil
      isTakingLongerThanExpected = false
      onTurnEnded?()
    }
    return outcome
  }

  private func runConnectionRecovery() async {
    let startedAt = connectionRecoveryScheduler.now()
    var failures = 1
    var nextAttemptAt = startedAt.advanced(
      by: connectionRecoveryRetryDelay(failures: failures)
    )

    while !Task.isCancelled {
      let now = connectionRecoveryScheduler.now()
      let elapsed = now - startedAt
      updateConnectionRecoveryPresentation(elapsed: elapsed)

      if now < nextAttemptAt {
        var wait = now.duration(to: nextAttemptAt)
        if connectionRecoveryMessage == nil,
          surfacedConnectionRecoveryError == nil,
          elapsed < connectionRecoveryStatusDelay
        {
          wait = min(wait, connectionRecoveryStatusDelay - elapsed)
        }
        do {
          try await connectionRecoveryScheduler.sleep(wait)
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
        guard retryable else {
          surfaceConnectionRecoveryFailure(message)
          return
        }
        failures += 1
        nextAttemptAt = connectionRecoveryScheduler.now().advanced(
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

  private func updateConnectionRecoveryPresentation(elapsed: Duration) {
    if elapsed >= connectionRecoveryStatusDelay, connectionRecoveryMessage == nil {
      connectionRecoveryMessage = "Reconnecting…"
    }
  }

  private func surfaceConnectionRecoveryFailure(_ message: String) {
    connectionRecoveryMessage = synchronizationMessage
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
    connectionRecoveryGeneration &+= 1
    connectionRecoveryTask?.cancel()
    connectionRecoveryTask = nil
    clearConnectionRecoveryPresentation()
  }

  private func clearConnectionRecoveryPresentation() {
    connectionRecoveryMessage = synchronizationMessage
    if let surfacedConnectionRecoveryError,
      errorMessage == surfacedConnectionRecoveryError
    {
      errorMessage = nil
    }
    surfacedConnectionRecoveryError = nil
  }

  var synchronizationMessage: String? {
    streamReconnectNotice.isVisible ? "Reconnecting…" : nil
  }

  func streamReconnectNoticeChanged(isVisible: Bool) {
    if isVisible {
      if connectionRecoveryMessage == nil { connectionRecoveryMessage = synchronizationMessage }
    } else if connectionRecoveryTask == nil, surfacedConnectionRecoveryError == nil {
      connectionRecoveryMessage = nil
    }
  }

  func applySynchronization(_ state: SessionStreamSynchronization) {
    guard state != .cursor else { return }
    streamSynchronization = state
    streamReconnectNotice.update(isActive: state == .reconnecting)
    if state == .caughtUp {
      Task {
        if presentsBotConversation { await refreshBotConversation() }
        await resendAfterReconnect()
      }
    }
    if state != .reconnecting {
      clearConnectionRecoveryPresentation()
    } else {
      connectionRecoveryMessage = synchronizationMessage
    }
  }

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
      return true
    } catch {
      errorMessage = serverErrorMessage(error)
      return false
    }
  }

  @discardableResult
  public func pauseGoal() async -> Bool {
    await setGoal(status: .paused)
  }

  @discardableResult
  public func resumeGoal() async -> Bool {
    await setGoal(status: .active)
  }

  @discardableResult
  public func clearGoal() async -> Bool {
    await startConsumer()
    do {
      try await transport.clearGoal()
      goal = nil
      return true
    } catch {
      errorMessage = serverErrorMessage(error)
      return false
    }
  }

  @discardableResult
  public func cancelAutoResume() async -> Bool {
    guard let pending = autoResume else { return true }
    autoResume = nil
    do {
      try await transport.cancelAutoResume()
      return true
    } catch {
      autoResume = pending
      errorMessage = serverErrorMessage(error)
      return false
    }
  }

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
}
