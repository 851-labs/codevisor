import Foundation
import ACPKit
import os

extension SessionController {
  public var serverAvailability: ServerAvailability {
    machines?.availability(for: project.serverId) ?? .ready
  }

  public var isServerReady: Bool { serverAvailability == .ready }

  public var isPausedForUpdate: Bool {
    updatePauseSubject != nil
  }

  public var updatingName: String {
    guard case let .harness(_, name) = updatePauseSubject else { return "Codevisor" }
    return name
  }

  private var updatePauseSubject: ServerUpdatePauseSubject? {
    machines?.updatePauseSubject(
      machineId: project.serverId,
      sessionId: serverSession?.id,
      harnessId: sessionHarnessId
    )
  }

  private var sessionHarnessId: String? {
    guard let persisted = serverSession?.harnessId, !persisted.isEmpty else { return selectedHarnessId }
    return persisted
  }

  public var sessionCwdURL: URL {
    if let cwd = serverSession?.cwd { return URL(fileURLWithPath: cwd) }
    if let sessionCwdOverride { return URL(fileURLWithPath: sessionCwdOverride) }
    return project.folderURL
  }

  public func retrySessionFailure() async {
    if case .failed = status, hasExistingAgentSession {
      let failedModel = model
      model = nil
      failedModel?.shutdown()
      await retry()
    } else if let model {
      await model.retrySessionFailure()
    } else {
      await retry()
    }
  }

  public func connectIfNeeded() async {
    guard hasSentFirst || hasExistingAgentSession || presentsBotConversation else { return }
    if connectionAttempt.isRunning {
      await connectionAttempt.waitForCompletion()
      return
    }
    guard !isFirstSendConnecting else { return }
    if let model, model !== cachedTranscriptModel {
      await model.reconcileIfStalled()
      return
    }
    guard model == nil || model === cachedTranscriptModel, !isConnecting, let serverSession else { return }
    guard !wantsNewWorktree || sessionCwdOverride != nil, sandboxTarget == nil else { return }
    let persistedHarnessId = serverSession.harnessId
    let harnessId = persistedHarnessId.isEmpty ? selectedHarness?.id : persistedHarnessId
    guard let harnessId, !harnessId.isEmpty else { return }
    let harnessName = selectedHarness?.name ?? harnessId
    connectionAttempt.start(
      harnessName: harnessName,
      connect: { self.model = try await self.connect(harnessId: harnessId) },
      onEvent: { self.handleConnectionEvent($0) })
    await connectionAttempt.waitForCompletion()
  }

  public func reconcileInFlightTurn() async {
    await model?.reconcileIfInFlight()
  }

  public func reconcileServerSummary(_ session: ChatSession, revision: Int?) async {
    guard let model, model.pendingOptimisticUserMessageIDs.isEmpty else { return }
    if let revision, let applied = model.serverEventCursor, applied >= revision { return }
    let serverFinished = [.idle, .unread, .errored].contains(session.sidebarState)
    guard
      (model.isSending && serverFinished)
        || (hasVisibleTranscript && !model.isSending && session.sidebarState == .inProgress)
    else { return }
    await model.reconcileFromServer()
  }

  private func handleConnectionEvent(_ event: SessionConnectionAttempt.Event) {
    switch event {
    case .starting(let harnessName):
      status = .connecting("Starting \(harnessName)…")
    case .waitingForServer:
      serverWaitMessage = "Waiting for the server..."
    case .connected:
      status = .idle
    case .cancelled:
      if case .connecting = status { status = .idle }
    case .failed(let message):
      if hasExistingAgentSession {
        didFinishExistingRuntimeConfiguration = true
        existingConfigurationError = message
        updateConfigurationValidationState()
        if let sessionId = serverSession?.id {
          finishInitialHistoryLoading(sessionId: sessionId, outcome: "failed")
        }
      }
      status = .failed(message)
    case .settled:
      serverWaitMessage = nil
    }
  }

  public func selectHarness(_ id: String) async {
    guard id != selectedHarnessId else { return }
    clearAutomaticSelection()
    let previousHarnessId = selectedHarnessId
    selectedHarnessId = id
    captureHarnessSelected(harnessId: id, previousHarnessId: previousHarnessId)
    if acceptsNewChatDefaults {
      seedRememberedConfig()
      composerDefaults?.rememberHarnessSelection(
        in: resolvedComposerDefaultsScope,
        harnessId: id
      )
    }
    if var serverSession {
      serverSession.harnessId = id
      self.serverSession = serverSession
    }
    await resolveDraftModelAvailabilityIfNeeded()
    await resolveDraftModelSettingsIfNeeded()
    await reconnect()
  }

  public func selectProject(_ project: Project) async {
    guard project.id != self.project.id else { return }
    let replacesPlaceholder = self.project.isRunTargetPlaceholder
    self.project = project
    sessionCwdOverride = nil
    worktreeName = nil
    if project.isRunTargetPlaceholder {
      wantsNewWorktree = false
    }
    if seedFromCachedServerCapabilities() {
      preparationState = .ready
    }
    if replacesPlaceholder {
      await prepare()
    }
    await reconnect()
  }

  public func retarget(
    to project: Project,
    serverClient client: any CodevisorServerClienting
  ) async {
    guard project.serverId != self.project.serverId else {
      await selectProject(project)
      return
    }
    retargetRevision &+= 1
    let revision = retargetRevision
    let selectionIntent = currentComposerSelectionIntent()
    automaticSelectionIntent = selectionIntent
    automaticSelectionNeedsResolution = selectionIntent != nil
    modelConfigurationResolutionRevision &+= 1
    isResolvingModelConfiguration = false
    harnessCapabilityRequestRevision &+= 1
    isRefreshingHarnessCapabilities = false
    serverClient = client
    draftModelAvailability = nil
    self.project = project
    attachments.reuploadAllAttachments()
    sessionCwdOverride = nil
    worktreeName = nil
    if project.isRunTargetPlaceholder {
      wantsNewWorktree = false
    }
    harnesses = []
    configOptionsByHarness = [:]
    modeStateByHarness = [:]
    supportsGoalsByHarness = [:]
    supportsSteeringByHarness = [:]
    pendingConfiguration.restoreValues([:])
    selectedHarnessId = nil
    if seedFromCachedServerCapabilities() {
      preparationState = .ready
    } else {
      preparationState = .loading
    }
    await prepare()
    guard revision == retargetRevision,
      self.project.serverId == project.serverId,
      self.project.id == project.id
    else { return }
    await reconnect()
  }

  public func adoptServerClient(_ client: any CodevisorServerClienting, forServer serverId: String) {
    guard project.serverId == serverId else { return }
    serverClient = client
  }

  public func reconnect() async {
    await connectionAttempt.cancelAndWait()
    model = nil
    status = .idle
    await connectIfNeeded()
  }

  public func retry() async {
    status = .idle
    if hasExistingAgentSession {
      if model == nil {
        didFinishExistingRuntimeConfiguration = false
        didLoadExistingRuntimeConfiguration = false
      }
      didLoadExistingHarnessCapabilities = false
      existingConfigurationError = nil
      updateConfigurationValidationState()
      async let capabilities: Void = prepareExistingSessionCapabilities()
      await connectIfNeeded()
      await capabilities
    } else {
      await prepare()
    }
  }

  func connect(harnessId: String) async throws -> SessionModel {
    guard let serverClient, var serverSession else {
      throw SessionControllerError.serverUnavailable
    }
    return try await connectServerSession(
      harnessId: harnessId,
      serverClient: serverClient,
      session: &serverSession
    )
  }

  private func connectServerSession(
    harnessId: String,
    serverClient: any CodevisorServerClienting,
    session: inout ChatSession
  ) async throws -> SessionModel {
    let scopedServerId = session.serverId
    if session.harnessId.isEmpty {
      session.harnessId = harnessId
    }
    if !session.hasAgentSession,
      let resumeAgentSessionId,
      !resumeAgentSessionId.isEmpty
    {
      session.agentSessionId = resumeAgentSessionId
    }
    let loadsExistingHistory = session.hasAgentSession
    if loadsExistingHistory {
      isLoadingInitialHistory = true
      initialHistoryLoadStartedAt =
        initialHistoryLoadStartedAt
        ?? ProcessInfo.processInfo.systemUptime
    }
    defer {
      if loadsExistingHistory {
        finishInitialHistoryLoading(sessionId: session.id, outcome: "failed")
      }
    }

    var preloadedTranscript: ServerTranscriptPage?
    var persistedRuntime: ServerSessionRuntimeMetadata?
    let workspaceId = hostWorkspaceId
    let transport: ServerSessionTransport
    let model: SessionModel
    let reusesCachedDisplay: Bool
    var cachedTranscriptLoad: Task<Void, Never>?
    if let cached = cachedTranscriptModel, cached === self.model {
      transport = cached.transport
      model = cached
      reusesCachedDisplay = true
      if loadsExistingHistory {
        finishInitialHistoryLoading(sessionId: session.id, outcome: "cached")
      }
    } else {
      transport = ServerSessionTransport(client: serverClient, sessionId: session.id)
      model = makeServerSessionModel(transport: transport, harnessId: harnessId, sessionId: session.id)
      reusesCachedDisplay = false
      cachedTranscriptLoad = startCachedTranscriptLoad(
        in: model, transport: transport, sessionId: session.id, serverId: scopedServerId,
        loadsExistingHistory: loadsExistingHistory)
    }
    let opened: ServerSessionOpenResult
    do {
      guard
        let response = try await serverClient.openSessionReturningData(
          session,
          project: project,
          workspaceId: workspaceId,
          transcriptLimit: SessionModel.initialTranscriptPageSize
        )
      else { throw CodevisorServerClientError.invalidResponse }
      opened = response
    } catch {
      await cachedTranscriptLoad?.value
      throw error
    }
    supersedeCachedTranscriptLoad()
    let showsCachedHistory = reusesCachedDisplay || cachedTranscriptModel === model
    session = try opened.response.session.chatSession(serverId: scopedServerId)
    preloadedTranscript = opened.response.transcript
    persistedRuntime = opened.response.runtime
    if let data = opened.data {
      transcriptCache?.store(data, machineId: scopedServerId, sessionId: session.id)
    }
    self.serverSession = session

    connectedHarnessId = harnessId
    if session.hasAgentSession, let agentSessionId = session.agentSessionId {
      connectedAgentSessionId = agentSessionId
      onAgentSessionCreated?(agentSessionId)
    }

    if showsCachedHistory {
      await model.loadHistoryReplacingCachedDisplay(preloaded: preloadedTranscript.map(transport.historyPage(from:)))
      cachedTranscriptModel = nil
    } else {
      await model.loadHistoryForInitialDisplay(
        preloaded: preloadedTranscript.map(transport.historyPage(from:))
      )
    }
    pendingPlanApproval = model.pendingPlanApproval
    if loadsExistingHistory {
      finishInitialHistoryLoading(sessionId: session.id, outcome: "ready")
    }
    analyticsUsageBaseline = model.usage

    if setupPhases.isEmpty, self.model == nil {
      self.model = model
    }

    if let metadata = persistedRuntime {
      model.applyRuntimeMetadata(modeState: metadata.modes, configOptions: metadata.configOptions)
      if !metadata.configOptions.isEmpty { configOptionsByHarness[harnessId] = metadata.configOptions }
      if let modes = metadata.modes { modeStateByHarness[harnessId] = modes }
      if let supportsGoals = metadata.supportsGoals { supportsGoalsByHarness[harnessId] = supportsGoals }
      if let supportsSteering = metadata.supportsSteering {
        supportsSteeringByHarness[harnessId] = supportsSteering
      }
    }
    didLoadExistingRuntimeConfiguration = true
    didFinishExistingRuntimeConfiguration = true
    updateConfigurationValidationState()

    captureChatCreatedIfNeeded(model: model, harnessId: harnessId)

    if !model.configOptions.isEmpty {
      configOptionsByHarness[harnessId] = model.configOptions
    }

    return model
  }
}
