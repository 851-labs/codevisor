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
    sendToAgent(delivery: resolvedDelivery(for: delivery))
  }

  public func compact() {
    guard supportsCompaction, acceptsSends else { return }

    let message = UserMessage(text: "/\(SessionSkills.compactCommand)", attachments: [])
    beginOptimisticSend()
    userSendSignal &+= 1
    sends.enqueue(message, attachmentIDs: [], route: .agent(.queue))
  }

  private func sendToAgent(delivery: ServerPromptDelivery) {
    guard canSend else { return }

    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    let sent = attachments.detachForSend()
    let message = UserMessage(text: text, attachments: sent.map(\.sentAttachment))
    rememberSentPreviews(of: sent)
    beginOptimisticSend()
    userSendSignal &+= 1
    if delivery != .queue {
      requestUserSendAnimation(for: message.id)
      pendingSendStartedAt = Date()
    }
    sends.enqueue(message, attachmentIDs: sent.map(\.id), route: .agent(delivery))
    composerText = ""
    wakeSandboxForSend()
    startChat(for: message.text)
  }

  private func beginOptimisticSend() {
    showsNewChatAfterSetupFailure = false
    if case .failed = status { status = .idle }
    if let notificationDelivery {
      Task { await notificationDelivery.prepareAuthorizationIfNeeded() }
    }
  }

  private func startChat(for prompt: String) {
    guard !hasSentFirst else { return }

    isFirstSendConnecting = true
    if project.isRunTargetPlaceholder, let provisional = provisionalCloneProject() { project = provisional }
    guard !project.isRunTargetPlaceholder else {
      isSubmitting = true
      return
    }
    Task { [weak self] in self?.acceptFirstSend(prompt) }
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

  func prepareSession(for prompt: String) async -> SessionPreparation {
    let showsSetupPhases = showsSetupPhasesForSubmission
    if let failure = await materializeRunTarget() { return .notStarted(failure) }
    acceptFirstSend(prompt)
    isSubmitting = false

    if let failure = await cloneRequestedProject(showsSetupPhases: showsSetupPhases) {
      return .failed(failure, returnsToNewChat: false)
    }
    if let failure = await createRequestedSandbox(showsSetupPhases: showsSetupPhases) {
      return .failed(failure, returnsToNewChat: false)
    }
    if let failure = await createRequestedWorktree(showsSetupPhases: showsSetupPhases) {
      return .failed(failure, returnsToNewChat: showsSetupPhases && !SessionSetupGroup.startedSandbox(in: setupPhases))
    }
    switch await sessionModel() {
    case let .success(model):
      await pendingConfiguration.apply(to: model)
      await applyPendingGoal(to: model)
      return .ready(model)
    case let .failure(failure):
      return .failed(failure.message, returnsToNewChat: showsSetupPhases)
    }
  }

  func applySetupFailure(_ preparation: SessionPreparation, restoreComposer: () -> Void) {
    switch preparation {
    case .ready:
      return
    case let .notStarted(message):
      restoreComposer()
      isSubmitting = false
      status = .failed(message)
    case let .failed(message, returnsToNewChat):
      restoreComposer()
      handleSetupFailure(message, returnsToNewChat: returnsToNewChat)
    }
  }

  private var showsSetupPhasesForSubmission: Bool {
    (pendingNewChatAnalytics || (!hasSentFirst && onFirstSend != nil))
      && resumeAgentSessionId?.isEmpty != false
  }

  private func materializeRunTarget() async -> String? {
    guard project.isRunTargetPlaceholder else { return nil }
    if let provisional = provisionalCloneProject() {
      project = provisional
      return nil
    }
    return await materializeScratchProject()
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

  private func createRequestedWorktree(showsSetupPhases: Bool) async -> String? {
    guard wantsNewWorktree, sessionCwdOverride == nil, !project.isScratch else { return nil }
    guard let failure = await createWorktree(showsSetupPhase: showsSetupPhases) else { return nil }

    mutateSetupPhase(id: SessionSetupPhase.worktreePhaseId) { $0.fail(message: failure) }
    return failure
  }

  private func sessionModel() async -> Result<SessionModel, SessionSetupFailure> {
    if let model { return .success(model) }
    guard let harness = selectedHarness else {
      return .failure(
        SessionSetupFailure(message: "No agent is installed. Install Claude Code or Codex and try again."))
    }

    status = .connecting("Starting \(harness.name)…")
    do {
      let model = try await connect(harnessId: harness.id)
      self.model = model
      status = .idle
      return .success(model)
    } catch {
      return .failure(SessionSetupFailure(message: serverErrorMessage(error)))
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
    guard let prompt = retryPrompt(before: assistantID) else { return }
    await model.retryResponse(to: prompt)
  }

  func retryPrompt(before assistantID: UUID) -> UserMessage? {
    guard
      let assistantIndex = conversation.firstIndex(where: { item in
        if case let .assistant(message) = item { return message.id == assistantID }
        return false
      })
    else { return nil }
    let earlier = conversation[..<assistantIndex].reversed()
    return earlier.compactMap(\.userPrompt).first ?? earlier.compactMap(\.eventPrompt).first
  }

  func createWorktree(showsSetupPhase: Bool) async -> String? {
    guard let serverClient else {
      return "Worktrees need the Codevisor server. Start it and try again."
    }
    let worktreeId = UUID().uuidString.lowercased()
    if showsSetupPhase, !hasRunningWorktreePhase { beginSetupPhase(.worktree()) }
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

  private var hasRunningWorktreePhase: Bool {
    setupPhases.contains { $0.id == SessionSetupPhase.worktreePhaseId && $0.isRunning }
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
