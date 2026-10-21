import Foundation

extension SessionController {
  func makeServerSessionModel(
    transport: ServerSessionTransport, harnessId: String, sessionId: UUID
  ) -> SessionModel {
    let model = SessionModel(
      serverTransport: transport,
      sessionId: sessionId.uuidString,
      modeState: modeStateByHarness[harnessId],
      configOptions: []
    )
    if presentsBotConversation { model.presentBotConversation() }
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
      guard userSendAnimationRequest?.messageID != messageID else { return }
      requestUserSendAnimation(for: messageID)
    }
    model.onPromptNotSteered = { [weak self] messageID in
      self?.cancelUserSendAnimation(for: messageID)
    }
    model.onQueuedPromptPromoted = { [weak self] messageID in
      guard let messageID else { return }
      self?.requestUserSendAnimation(for: messageID)
    }
    model.onPlanApprovalChanged = { [weak self] required in
      self?.pendingPlanApproval = required
    }
    return model
  }

  func startCachedTranscriptLoad(
    in model: SessionModel, transport: ServerSessionTransport, sessionId: UUID, serverId: String,
    loadsExistingHistory: Bool
  ) -> Task<Void, Never>? {
    guard setupPhases.isEmpty, self.model == nil, let transcriptCache else { return nil }
    transcriptCacheLoadGeneration &+= 1
    let generation = transcriptCacheLoadGeneration
    return Task { [weak self, weak model] in
      let page = await Self.loadCachedTranscriptPage(
        cache: transcriptCache, transport: transport, machineId: serverId, sessionId: sessionId)
      guard let self, let model, let page, transcriptCacheLoadGeneration == generation,
        setupPhases.isEmpty, self.model == nil
      else { return }
      model.showCachedHistory(page)
      self.model = model
      cachedTranscriptModel = model
      if loadsExistingHistory {
        finishInitialHistoryLoading(sessionId: sessionId, outcome: "cached")
      }
    }
  }

  func supersedeCachedTranscriptLoad() {
    transcriptCacheLoadGeneration &+= 1
  }

  @concurrent
  nonisolated static func loadCachedTranscriptPage(
    cache: TranscriptPageCache, transport: ServerSessionTransport, machineId: String, sessionId: UUID
  ) async -> TranscriptHistoryPage? {
    guard let data = await cache.load(machineId: machineId, sessionId: sessionId) else { return nil }
    guard let cached = try? JSONDecoder().decode(ServerSessionOpenResponse.self, from: data) else {
      cache.remove(machineId: machineId, sessionId: sessionId)
      return nil
    }
    let page = transport.historyPage(from: cached.transcript)
    return page.conversation.isEmpty ? nil : page
  }
}
