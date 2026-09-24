import Foundation

extension SessionController {
  /// The chat's model, built before its open request so a cached page can be
  /// on screen while that request is in flight.
  func makeServerSessionModel(
    transport: ServerSessionTransport, harnessId: String, sessionId: UUID
  ) -> SessionModel {
    // Build the composer from saved option definitions. Opening history
    // never starts the provider; explicit runtime actions validate selections.
    let initialConfigOptions =
      configOptionsByHarness[harnessId]
      ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
    let model = SessionModel(
      serverTransport: transport,
      sessionId: sessionId.uuidString,
      modeState: modeStateByHarness[harnessId],
      configOptions: initialConfigOptions
    )
    model.onTurnEnded = { [weak self, weak model] in
      self?.liveTurnEndRevision &+= 1
      if let model { self?.captureTurnEnded(model) }
      self?.noteTurnEndedForPlanApproval()
      self?.onTurnEnded?()
    }
    model.onPromptAccepted = { [weak self, weak model] attachmentCount, isQueued in
      self?.configurationAdjustmentMessage = nil
      self?.captureMessageSent(model: model, attachmentCount: attachmentCount, isQueued: isQueued)
    }
    model.onLocalUserMessageAppended = { [weak self] messageID in
      guard let self, pendingUserMessage?.id == messageID else { return }
      pendingUserMessage = nil
      // Ordinary sends already own a request before their optimistic row
      // is published. Keep this as a fallback for any model attachment
      // race; a first send retains its existing optimistic destination.
      guard userSendAnimationRequest?.messageID != messageID else { return }
      requestUserSendAnimation(for: messageID, destination: .activeTurn)
    }
    model.onQueuedPromptPromoted = { [weak self] messageID in
      guard let messageID else { return }
      self?.requestUserSendAnimation(for: messageID, destination: .activeTurn)
    }
    model.onPlanApprovalChanged = { [weak self] required in
      self?.pendingPlanApproval = required
    }
    return model
  }

  /// Shows the chat's last saved page and publishes the model, so opening a
  /// chat never waits on the network when this device has seen it before.
  /// Sending waits for the open request like it always has. Returns false
  /// when there is nothing cached (or a first-send setup owns the model).
  func showCachedTranscript(
    in model: SessionModel, transport: ServerSessionTransport, sessionId: UUID, serverId: String
  ) -> Bool {
    guard setupPhases.isEmpty, self.model == nil, let transcriptCache,
      let data = transcriptCache.load(machineId: serverId, sessionId: sessionId)
    else { return false }
    guard let cached = try? JSONDecoder().decode(ServerSessionOpenResponse.self, from: data) else {
      transcriptCache.remove(machineId: serverId, sessionId: sessionId)
      return false
    }
    let page = transport.historyPage(from: cached.transcript)
    guard !page.conversation.isEmpty else { return false }
    model.showCachedHistory(page)
    self.model = model
    cachedTranscriptModel = model
    return true
  }
}
