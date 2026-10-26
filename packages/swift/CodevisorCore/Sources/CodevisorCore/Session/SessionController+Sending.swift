import Foundation
import ACPKit
import os

extension SessionController {
  public func interceptsSend(_ delivery: ServerPromptDelivery) -> Bool {
    sendInterceptor?(delivery) == true
  }

  public func requestSubmit() {
    submitRequest &+= 1
  }

  public func send(delivery: ServerPromptDelivery = .steer) async {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composerAttachments.isEmpty, isReadyToSubmit else { return }
    beginSubmission()
    defer { isFirstSendConnecting = false }

    let attachments: [Attachment]
    if composerAttachments.isEmpty {
      attachments = []
    } else {
      guard let collected = await self.attachments.collectAttachmentsForSend() else {
        isSubmitting = false
        return
      }
      attachments = collected
    }
    let outgoingMessage = UserMessage(text: text, attachments: attachments)
    let resolvedDelivery = resolvedDelivery(for: delivery)
    let shouldAnimateTranscriptSend = !sendLandsInQueue(delivery)
    userSendSignal &+= 1

    if shouldAnimateTranscriptSend {
      requestUserSendAnimation(for: outgoingMessage.id)
      pendingSendStartedAt = Date()
      pendingUserMessage = outgoingMessage
    }

    let staged = composerAttachments
    composerText = ""
    self.attachments.clearAfterCollecting()

    func restoreComposer() {
      composerText = text
      self.attachments.restore(staged)
      pendingUserMessage = nil
      cancelUserSendAnimation(for: outgoingMessage.id)
    }

    guard let model = await prepareSession(for: text, restoreComposer: restoreComposer) else { return }
    await submit(outgoingMessage, to: model, delivery: resolvedDelivery)
    self.attachments.releaseStagedFiles(of: staged)
  }

  var isReadyToSubmit: Bool {
    !isConnecting
      && isServerReady
      && !isPausedForUpdate
      && configurationValidationState == .ready
      && !requiresModelSelection
      && !isSubmitting
  }

  func beginSubmission() {
    showsNewChatAfterSetupFailure = false
    status = .idle
    if let notificationDelivery {
      Task { await notificationDelivery.prepareAuthorizationIfNeeded() }
    }
    isSubmitting = true
    if !hasSentFirst {
      isFirstSendConnecting = true
    }
  }

  @discardableResult
  func prepareSession(for prompt: String, restoreComposer: () -> Void) async -> SessionModel? {
    let showsSetupPhases = showsSetupPhasesForSubmission
    guard await materializeRunTarget(restoreComposer: restoreComposer) else { return nil }
    acceptFirstSend(prompt)
    isSubmitting = false

    guard
      await createRequestedEphemeralMachine(showsSetupPhases: showsSetupPhases, restoreComposer: restoreComposer)
    else { return nil }

    guard await createRequestedWorktree(showsSetupPhases: showsSetupPhases, restoreComposer: restoreComposer)
    else { return nil }

    guard let model = await sessionModel(showsSetupPhases: showsSetupPhases, restoreComposer: restoreComposer)
    else { return nil }
    await pendingConfiguration.apply(to: model)
    await applyPendingGoal(to: model)
    return model
  }

  private var showsSetupPhasesForSubmission: Bool {
    (pendingNewChatAnalytics || (!hasSentFirst && onFirstSend != nil))
      && resumeAgentSessionId?.isEmpty != false
  }

  private func materializeRunTarget(restoreComposer: () -> Void) async -> Bool {
    guard project.isRunTargetPlaceholder else { return true }
    guard let failure = await materializeScratchProject() else { return true }

    restoreComposer()
    isSubmitting = false
    status = .failed(failure)
    return false
  }

  private func acceptFirstSend(_ prompt: String) {
    guard !hasSentFirst else { return }

    firstSendSelections = rememberedConfigValues
    hasSentFirst = true
    if onFirstSend != nil {
      pendingNewChatAnalytics = true
    }
    onFirstSend?(prompt)
    onFirstSend = nil
  }

  private func createRequestedWorktree(showsSetupPhases: Bool, restoreComposer: () -> Void) async -> Bool {
    guard wantsNewWorktree, sessionCwdOverride == nil, !project.isScratch else { return true }
    guard let failure = await createWorktree(showsSetupPhase: showsSetupPhases) else { return true }

    restoreComposer()
    handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
    return false
  }

  private func sessionModel(showsSetupPhases: Bool, restoreComposer: () -> Void) async -> SessionModel? {
    if let model { return model }
    guard let harness = selectedHarness else {
      let message = "No agent is installed. Install Claude Code or Codex and try again."
      restoreComposer()
      handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
      return nil
    }

    status = .connecting("Starting \(harness.name)…")
    do {
      let model = try await connect(harnessId: harness.id)
      self.model = model
      status = .idle
      return model
    } catch {
      let message = serverErrorMessage(error)
      restoreComposer()
      handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
      return nil
    }
  }

  private func submit(_ message: UserMessage, to model: SessionModel, delivery: ServerPromptDelivery) async {
    let startedAt = pendingSendStartedAt
    Task { [weak self] in
      await model.send(message, startedAt: startedAt, delivery: delivery)
      if self?.pendingUserMessage?.id == message.id {
        self?.pendingUserMessage = nil
      }
    }
  }

  func requestUserSendAnimation(for messageID: UUID) {
    userSendAnimationRequest = userSendAnimationCoordinator.issue(for: messageID)
  }

  public func claimUserSendAnimation(_ request: UserSendAnimationRequest) -> Bool {
    userSendAnimationCoordinator.claim(request)
  }

  func cancelUserSendAnimation(for messageID: UUID) {
    guard let request = userSendAnimationRequest, request.messageID == messageID else { return }
    userSendAnimationCoordinator.cancel(request)
    userSendAnimationRequest = nil
  }

  public func retryTurn(_ assistantID: UUID) async {
    guard let model, !model.isSending, !isConnecting, !isSubmitting else { return }
    guard
      let assistantIndex = model.conversation.firstIndex(where: { item in
        if case let .assistant(message) = item { return message.id == assistantID }
        return false
      })
    else { return }
    guard
      let prompt = model.conversation[..<assistantIndex].reversed().compactMap(\.userPrompt).first
    else { return }
    await model.retryResponse(to: prompt)
  }

  func createWorktree(showsSetupPhase: Bool) async -> String? {
    guard let serverClient else {
      return "Worktrees need the Codevisor server. Start it and try again."
    }
    let worktreeId = UUID().uuidString.lowercased()
    if showsSetupPhase { beginSetupPhase(.worktree()) }
    status = .connecting("Setting up worktree…")
    let log = WorktreeSetupEvent.liveLog(serverClient, worktreeId: worktreeId)
    let follow = Task { [weak self] in
      for await entry in log {
        self?.mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) {
          $0.appendLog(stream: entry.stream, line: entry.line)
        }
      }
    }
    defer { follow.cancel() }
    do {
      let worktree = try await serverClient.createWorktree(
        projectId: project.id,
        id: worktreeId,
        name: nil
      )
      sessionCwdOverride = worktree.path
      worktreeName = worktree.name
      if var session = serverSession {
        session.worktreeName = worktree.name
        session.cwd = worktree.path
        serverSession = session
      }
      onWorktreeCreated?(worktree)
      mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) { $0.succeed() }
      status = .idle
      return nil
    } catch let CodevisorServerClientError.httpStatus(_, message) {
      return WorktreeCreator.failureMessage(from: message)
    } catch {
      return serverErrorMessage(error)
    }
  }

  func materializeScratchProject() async -> String? {
    guard let serverClient else {
      return "Starting a chat needs the Codevisor server. Start it and try again."
    }
    status = .connecting("Preparing folder…")
    do {
      let created = try await serverClient.createScratchProject(id: UUID())
      let scratch = try created.project(serverId: project.serverId)
      onScratchProjectCreated?(scratch)
      project = scratch
      status = .idle
      return nil
    } catch {
      status = .idle
      return serverErrorMessage(error)
    }
  }

  func handleSetupFailure(_ message: String, returnsToNewChat: Bool) {
    if returnsToNewChat {
      setupPhases.removeAll()
      hasSentFirst = false
      pendingNewChatAnalytics = false
      showsNewChatAfterSetupFailure = true
      status = .failed(message)
      onSetupFailed?()
      onSetupFailed = nil
      return
    }
    status = .failed(message)
  }

  func beginSetupPhase(_ phase: SessionSetupPhase) {
    setupPhases.removeAll { $0.id == phase.id }
    setupPhases.append(phase)
  }

  func mutateSetupPhase(id: String, _ transform: (inout SessionSetupPhase) -> Void) {
    guard let index = setupPhases.firstIndex(where: { $0.id == id }) else { return }
    transform(&setupPhases[index])
  }

  public func stop() async {
    await model?.cancel()
  }

  @discardableResult
  public func updateQueuedPrompt(id: String, text: String, attachments: [Attachment]? = nil) async -> Bool {
    await model?.promptQueue.update(id: id, text: text, attachments: attachments) ?? false
  }

  @discardableResult
  public func reorderQueuedPrompts(ids: [String]) async -> Bool {
    await model?.promptQueue.reorder(ids: ids) ?? false
  }

  @discardableResult
  public func deleteQueuedPrompt(id: String) async -> Bool {
    guard let model else { return false }
    let deleted = await model.promptQueue.delete(id: id)
    if deleted, editingQueuedPromptID == id { cancelEditingQueuedPrompt() }
    return deleted
  }

  public func setMode(_ modeId: String) async {
    if let model {
      pendingConfiguration.setMode(nil)
      await model.setMode(modeId)
    } else {
      pendingConfiguration.setMode(modeId)
    }
  }
}
