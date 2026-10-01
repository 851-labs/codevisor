import Foundation

extension SessionController {
  /// The chat's model, built before its open request so a cached page can be
  /// on screen while that request is in flight.
  func makeServerSessionModel(
    transport: ServerSessionTransport, harnessId: String, sessionId: UUID
  ) -> SessionModel {
    // The model starts without options: only the chat's runtime reports
    // them. Until it does, the composer shows the chat's saved values over
    // catalog option lists (`existingChatConfigOptions`) — never a
    // catalog or inspection default.
    let model = SessionModel(
      serverTransport: transport,
      sessionId: sessionId.uuidString,
      modeState: modeStateByHarness[harnessId],
      configOptions: []
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
      requestUserSendAnimation(for: messageID)
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

  /// Starts reading the chat's last saved page off the main actor. When it
  /// arrives, and this connect still owns the chat, the page is shown and the
  /// model published, so opening a chat never waits on the network when this
  /// device has seen it before. Sending waits for the open request like it
  /// always has. Returns nil when there is nothing to read (or a first-send
  /// setup owns the model).
  ///
  /// The read races the open request. Whichever wins, the server's page is
  /// what remains: `supersedeCachedTranscriptLoad()` drops a read still in
  /// flight once the open response is in hand.
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

  /// Drops any cached-page read still in flight: fresher data owns the chat.
  func supersedeCachedTranscriptLoad() {
    transcriptCacheLoadGeneration &+= 1
  }

  /// Reads, decodes, and converts the saved open response. A page that no
  /// longer decodes is removed; an empty one is not worth showing.
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
