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
      if let model {
        self?.captureTurnEnded(model)
        self?.refreshCachedTranscript(of: model)
      }
      self?.noteTurnEndedForPlanApproval()
      self?.onTurnEnded?()
    }
    model.onPromptAccepted = { [weak self, weak model] acceptance in
      self?.configurationAdjustmentMessage = nil
      self?.captureMessageSent(model: model, acceptance: acceptance)
    }
    model.onLocalUserMessageAppended = { [weak self] messageID in
      guard let self, sends.route(of: messageID)?.landsInPromptQueue == true else { return }
      requestUserSendAnimation(for: messageID)
    }
    model.onPromptNotSteered = { [weak self] messageID in
      self?.cancelUserSendAnimation(for: messageID)
    }
    model.onQueuedPromptPromoted = { [weak self] messageID in
      guard let self, let messageID else { return }
      if hasVisibleTranscript { onQueuedPromptWillFly?(messageID) }
      requestUserSendAnimation(for: messageID)
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

  var cacheRecorder: SessionCacheRecorder? {
    guard let clientCache, let serverSession else { return nil }

    return SessionCacheRecorder(cache: clientCache, machineId: serverSession.serverId, chatId: serverSession.id)
  }

  func rememberOpenedTranscript(_ data: Data, machineId: String, sessionId: UUID) {
    transcriptCache?.store(data, machineId: machineId, sessionId: sessionId)
    cacheRecorder?.recordOpened(data)
  }

  func recordingPages(of transport: ServerSessionTransport) -> ServerSessionTransport {
    cacheRecorder?.recordingPages(of: transport) ?? transport
  }

  func recordQueuedSends() {
    cacheRecorder?.recordQueuedSends(sends.unsent)
  }

  func refreshCachedTranscript(of model: SessionModel) {
    guard let recorder = cacheRecorder else { return }

    Task { [weak model] in
      guard let transport = model?.transport else { return }
      _ = try? await transport.transcriptPage(limit: SessionModel.initialTranscriptPageSize)
      guard let model else { return }
      recorder.audit(model)
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
