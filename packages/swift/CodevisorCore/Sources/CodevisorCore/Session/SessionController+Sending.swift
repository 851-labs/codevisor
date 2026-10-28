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
    if presentsBotConversation { return sendToBot() }
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
    await deliver(OutgoingSend(message: outgoingMessage, staged: staged), delivery: resolvedDelivery)
  }

  func deliver(_ outgoing: OutgoingSend, delivery: ServerPromptDelivery) async {
    func restoreComposer() {
      composerText = outgoing.message.text
      attachments.restore(outgoing.staged)
      pendingUserMessage = nil
      cancelUserSendAnimation(for: outgoing.message.id)
    }

    func holdForRetry() {
      heldSend = outgoing
      pendingUserMessage = nil
    }

    guard
      let model = await prepareSession(
        for: outgoing.message.text, restoreComposer: restoreComposer, holdForRetry: holdForRetry)
    else { return }
    await submit(outgoing.message, to: model, delivery: delivery)
    attachments.releaseStagedFiles(of: outgoing.staged)
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
    discardHeldSend()
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
  func prepareSession(
    for prompt: String, restoreComposer: () -> Void, holdForRetry: (() -> Void)? = nil
  ) async -> SessionModel? {
    let showsSetupPhases = showsSetupPhasesForSubmission
    guard await materializeRunTarget(restoreComposer: restoreComposer) else { return nil }
    acceptFirstSend(prompt)
    isSubmitting = false

    guard
      await createRequestedSandbox(
        showsSetupPhases: showsSetupPhases, restoreComposer: restoreComposer, holdForRetry: holdForRetry)
    else { return nil }

    guard
      await createRequestedWorktree(
        showsSetupPhases: showsSetupPhases, restoreComposer: restoreComposer, holdForRetry: holdForRetry)
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

  private func createRequestedWorktree(
    showsSetupPhases: Bool, restoreComposer: () -> Void, holdForRetry: (() -> Void)?
  ) async -> Bool {
    guard wantsNewWorktree, sessionCwdOverride == nil, !project.isScratch else { return true }
    guard let failure = await createWorktree(showsSetupPhase: showsSetupPhases) else { return true }

    guard SessionSetupGroup.startedSandbox(in: setupPhases) else {
      restoreComposer()
      handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
      return false
    }
    mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) { $0.fail(message: failure) }
    if let holdForRetry { holdForRetry() } else { restoreComposer() }
    handleSetupFailure(failure, returnsToNewChat: false)
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

extension SessionController {
  static let closedChatReason = "This chat was closed."

  private func sendToBot() {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composerAttachments.isEmpty else { return }

    let sent = attachments.detachForSend()
    let message = UserMessage(text: text, attachments: sent.map(\.sentAttachment))
    rememberSentPreviews(of: sent)
    userSendSignal &+= 1
    requestUserSendAnimation(for: message.id)
    botSends.enqueue(message, attachmentIDs: sent.map(\.id), afterSequence: model?.botMessages.last?.sequence)
    composerText = ""
  }

  public var hasUnsentBotMessages: Bool {
    !botSends.unsentMessages.isEmpty
  }

  var botSendReadiness: BotSendQueue.Readiness {
    if case let .failed(message) = configurationValidationState { return .failed(message) }
    let isSettled = isServerReady && !isConnecting && !isPausedForUpdate && configurationValidationState == .ready
    return isSettled ? .ready : .waiting(botUnreachableReason)
  }

  func connectBot(for message: UserMessage) async -> BotSendQueue.Preparation {
    guard let model = await prepareSession(for: message.text, restoreComposer: {}) else {
      return .failed(botConnectionFailure)
    }
    guard !requiresModelSelection else { return .failed("Pick a model for this bot in its settings, then try again.") }

    return .ready(model)
  }

  func rememberUploaded(_ uploaded: Attachment, sentAs sentFileID: String) {
    guard uploaded.fileId != sentFileID else { return }

    SentAttachmentAliases.remember(uploaded: uploaded.fileId, sentAs: sentFileID)
    guard let preview = sentAttachmentPreviews.preview(for: sentFileID) else { return }
    sentAttachmentPreviews.remember(preview, for: uploaded.fileId)
  }

  private func rememberSentPreviews(of sent: [ComposerAttachment]) {
    for attachment in sent where attachment.isImage {
      guard let preview = attachment.sentPreviewData else { continue }
      sentAttachmentPreviews.remember(preview, for: attachment.sentFileID)
    }
  }

  private var botUnreachableReason: String {
    serverWaitMessage ?? "The bot isn’t reachable right now. Try again in a moment."
  }

  private var botConnectionFailure: String {
    if case let .failed(message) = status { return message }
    return "Couldn’t start the bot. Try again in a moment."
  }
}
