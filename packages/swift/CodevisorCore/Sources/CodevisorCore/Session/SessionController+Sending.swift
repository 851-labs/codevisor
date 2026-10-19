import Foundation
import ACPKit
import os

extension SessionController {
  public func send() async {
    let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composerAttachments.isEmpty,
      !isConnecting,
      isServerReady,
      configurationValidationState == .ready,
      !requiresModelSelection,
      !isSubmitting
    else { return }
    showsNewChatAfterSetupFailure = false
    status = .idle
    if let notificationDelivery {
      Task { await notificationDelivery.prepareAuthorizationIfNeeded() }
    }
    isSubmitting = true
    if !hasSentFirst {
      isFirstSendConnecting = true
    }
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
    let shouldAnimateTranscriptSend = !isSending || presentsBotConversation
    userSendSignal &+= 1

    if shouldAnimateTranscriptSend {
      requestUserSendAnimation(for: outgoingMessage.id)
      pendingSendStartedAt = Date()
      pendingUserMessage = outgoingMessage
    }

    let showsSetupPhases =
      (pendingNewChatAnalytics || (!hasSentFirst && onFirstSend != nil))
      && resumeAgentSessionId?.isEmpty != false
    let staged = composerAttachments
    composerText = ""
    self.attachments.clearAfterCollecting()
    if project.isRunTargetPlaceholder {
      if let failure = await materializeScratchProject() {
        composerText = text
        self.attachments.restore(staged)
        pendingUserMessage = nil
        cancelUserSendAnimation(for: outgoingMessage.id)
        isSubmitting = false
        status = .failed(failure)
        return
      }
    }
    if !hasSentFirst {
      firstSendSelections = rememberedConfigValues
      hasSentFirst = true
      if onFirstSend != nil {
        pendingNewChatAnalytics = true
      }
      onFirstSend?(text)
      onFirstSend = nil
    }
    isSubmitting = false

    func restoreComposer() {
      composerText = text
      self.attachments.restore(staged)
      pendingUserMessage = nil
      cancelUserSendAnimation(for: outgoingMessage.id)
    }

    if wantsNewWorktree, sessionCwdOverride == nil, !project.isScratch {
      if let failure = await createWorktree(showsSetupPhase: showsSetupPhases) {
        restoreComposer()
        handleSetupFailure(failure, returnsToNewChat: showsSetupPhases)
        return
      }
    }

    if let model {
      await pendingConfiguration.apply(to: model)
      await applyPendingGoal(to: model)
      await model.send(outgoingMessage, startedAt: pendingSendStartedAt)
      self.attachments.releaseStagedFiles(of: staged)
      if pendingUserMessage?.id == outgoingMessage.id {
        pendingUserMessage = nil
      }
      return
    }

    guard let harness = selectedHarness else {
      let message = "No agent is installed. Install Claude Code or Codex and try again."
      restoreComposer()
      handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
      return
    }
    status = .connecting("Starting \(harness.name)…")
    do {
      let model = try await connect(harnessId: harness.id)
      self.model = model
      status = .idle
      await pendingConfiguration.apply(to: model)
      await applyPendingGoal(to: model)
      await model.send(outgoingMessage, startedAt: pendingSendStartedAt)
      self.attachments.releaseStagedFiles(of: staged)
      if pendingUserMessage?.id == outgoingMessage.id {
        pendingUserMessage = nil
      }
    } catch {
      let message = serverErrorMessage(error)
      restoreComposer()
      handleSetupFailure(message, returnsToNewChat: showsSetupPhases)
    }
  }

  func requestUserSendAnimation(for messageID: UUID) {
    userSendAnimationRequest = userSendAnimationCoordinator.issue(for: messageID)
  }

  public func claimUserSendAnimation(_ request: UserSendAnimationRequest) -> Bool {
    userSendAnimationCoordinator.claim(request)
  }

  private func cancelUserSendAnimation(for messageID: UUID) {
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
      let prompt = model.conversation[..<assistantIndex].reversed().compactMap({ item in
        if case let .user(message) = item { return message }
        return nil
      }).first
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
  public func updateQueuedPrompt(id: String, text: String) async -> Bool {
    await model?.updateQueuedPrompt(id: id, text: text) ?? false
  }

  @discardableResult
  public func reorderQueuedPrompts(ids: [String]) async -> Bool {
    await model?.reorderQueuedPrompts(ids: ids) ?? false
  }

  @discardableResult
  public func deleteQueuedPrompt(id: String) async -> Bool {
    await model?.deleteQueuedPrompt(id: id) ?? false
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
