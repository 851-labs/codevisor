import Foundation
import ACPKit
import os

extension SessionController {
  /// Resolve the live target on every read, including after a draft switch.
  /// Isolated controllers without a fleet retain their injected-client behavior.
  public var serverAvailability: ServerAvailability {
    machines?.availability(for: project.serverId) ?? .ready
  }

  public var isServerReady: Bool { serverAvailability == .ready }

  /// The directory the agent runs in: the session's server-resolved cwd
  /// (the workspace's one working directory — project folder or worktree),
  /// or the project folder for plain drafts.
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

  /// Connects or resumes the selected harness after a chat has started. New
  /// chat pickers come from capability inspection; a deferred durable record
  /// must not create its real agent until the first send is accepted. Safe to
  /// call repeatedly.
  ///
  /// A server that refuses connections here is usually just booting — after
  /// an update the app relaunches before its managed server is listening
  /// again. Unreachable errors therefore retry behind a calm loading state
  /// (softened past 5s) and only surface the failure banner — with its
  /// Restart remedy — after 10s without contact.
  public func connectIfNeeded() async {
    // Central lifecycle invariant: callers such as focus routing and view
    // setup are deliberately broad. Even if one reaches this method for a
    // deferred record, only first send may cross the draft/runtime boundary.
    guard hasSentFirst || hasExistingAgentSession else { return }
    // The connect attempt is CONTROLLER-owned, not a child of the view
    // task that called this. Controllers are cached beyond any single
    // mount, and the first open of a remotely created chat re-hosts its
    // pane mid-connect (the container's workspace/tab fix-up bumps the
    // layout): a view-owned attempt died with that remount — after
    // painting the transcript and then UN-publishing it in the runtime
    // catch — while the remounted view's retry bounced off the stale
    // `.connecting` status below, leaving the chat permanently empty.
    // Joining the surviving attempt fixes both halves of that race.
    if connectionAttempt.isRunning {
      await connectionAttempt.waitForCompletion()
      return
    }
    // A first send is connecting on its own path; it publishes the model.
    guard !isFirstSendConnecting else { return }
    if let model, model !== cachedTranscriptModel {
      // A cached chat re-binds without reconnecting. If its turn has
      // been quiet past the stall window, re-verify against durable
      // history on re-entry — "navigate away and back" then heals a
      // stuck view instead of waiting out the next stall cycle.
      await model.reconcileIfStalled()
      return
    }
    guard model == nil || model === cachedTranscriptModel, !isConnecting, let serverSession else { return }
    // A worktree draft has no cwd until the worktree is created on first
    // send; connecting now would pin the agent to the project folder.
    guard !wantsNewWorktree || sessionCwdOverride != nil else { return }
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

  /// Foreground/network-recovery hook: re-verifies this chat's in-flight
  /// turn against durable server history (see
  /// `SessionModel.reconcileIfInFlight`). Includes a visible idle chat;
  /// hidden idle chats are a no-op.
  public func reconcileInFlightTurn() async {
    await model?.reconcileIfInFlight()
  }

  public func reconcileServerSummary(_ session: ChatSession, revision: Int?) async {
    // A sidebar event can predate a locally submitted prompt whose echo has
    // not arrived yet. It cannot authoritatively end that optimistic turn.
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
      // Supersession must clear connecting before its successor checks admission.
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

  /// Selects a different harness (user action) and reconnects.
  public func selectHarness(_ id: String) async {
    guard id != selectedHarnessId else { return }
    clearAutomaticSelection()
    let previousHarnessId = selectedHarnessId
    selectedHarnessId = id
    captureHarnessSelected(harnessId: id, previousHarnessId: previousHarnessId)
    if acceptsNewChatDefaults {
      // Start the new harness from its own remembered selections rather
      // than pending edits made under the previous harness.
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

  /// Changes the project (new-chat picker) and reconnects.
  public func selectProject(_ project: Project) async {
    guard project.id != self.project.id else { return }
    let replacesPlaceholder = self.project.isRunTargetPlaceholder
    self.project = project
    // A worktree kept from a reverted first send belongs to the old
    // project; the new project gets its own on the next send.
    sessionCwdOverride = nil
    worktreeName = nil
    // "No project" has no repository to cut a worktree from; a preference
    // carried over from the previous git project must not survive.
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

  /// Re-points a DRAFT at a project on another machine: swaps the server
  /// client along with the project so capability probes, the harness
  /// catalog, and the eventual first send all hit the picked project's
  /// machine. The composer's typed state stays live — the machine switch
  /// itself waits for first send. Same-machine picks fall through to
  /// `selectProject`.
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
    // Supersede model-dependent inspection work that was started with the
    // old machine's client and catalog.
    modelConfigurationResolutionRevision &+= 1
    isResolvingModelConfiguration = false
    harnessCapabilityRequestRevision &+= 1
    isRefreshingHarnessCapabilities = false
    serverClient = client
    // The carried pick is re-validated against the destination's catalog.
    draftModelAvailability = nil
    self.project = project
    // Staged attachments were uploaded to the old machine, and file ids
    // are machine-local: sending their refs to the new machine fails its
    // send-time lookup with "Unknown attachment file". Re-upload from the
    // retained bytes so the refs match the client that will send them.
    attachments.reuploadAllAttachments()
    // Any kept worktree belongs to the old machine's project, and "No
    // project" on the new machine has nothing to cut one from.
    sessionCwdOverride = nil
    worktreeName = nil
    if project.isRunTargetPlaceholder {
      wantsNewWorktree = false
    }
    // The old machine's catalog must never survive a machine switch: a
    // target with no cached snapshot would otherwise keep rendering the
    // previous server's harnesses, models, and sign-in rows until the
    // live fetch lands.
    harnesses = []
    configOptionsByHarness = [:]
    modeStateByHarness = [:]
    supportsGoalsByHarness = [:]
    pendingConfiguration.restoreValues([:])
    selectedHarnessId = nil
    if seedFromCachedServerCapabilities() {
      preparationState = .ready
    } else {
      preparationState = .loading
    }
    // Reload harnesses/capabilities from the new machine, then rebuild
    // whatever connection state a draft is allowed to hold.
    await prepare()
    guard revision == retargetRevision,
      self.project.serverId == project.serverId,
      self.project.id == project.id
    else { return }
    await reconnect()
  }

  /// Swaps in a freshly resolved client for the draft's CURRENT machine —
  /// used when a machine that wasn't routable at mount (a cloud relay
  /// still connecting) becomes reachable. Same machine, better transport;
  /// a machine CHANGE goes through `retarget(to:serverClient:)`.
  public func adoptServerClient(_ client: any CodevisorServerClienting, forServer serverId: String) {
    guard project.serverId == serverId else { return }
    serverClient = client
  }

  /// Tears down any connection and reconnects — used when the harness or
  /// project changes on the new-chat page.
  public func reconnect() async {
    // Supersede a controller-owned eager connect explicitly: cancel it and
    // wait for it to settle so its failure handling cannot clobber the
    // fresh attempt's status/model below.
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

  // MARK: - Connection

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
    // `ServerSession.serverId` belongs to the remote server's namespace
    // (often simply "local"). Preserve the connection scope already held
    // by this controller so attention, navigation, and cache lookups keep
    // addressing the same client-visible machine after open/upsert.
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
      // An earlier attempt already shows this chat's cached page; keep it.
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
      // A chat opened before shows its last page from this device as soon
      // as it is read -- offline too -- and updates in place when the
      // server's arrives. The read runs off the main actor, alongside the
      // open request.
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
      // Without the server's page the saved one is all there is: let a read
      // in flight show it before the failure is handled.
      await cachedTranscriptLoad?.value
      throw error
    }
    // The server's page is in hand; a saved page not yet shown never will be.
    supersedeCachedTranscriptLoad()
    let showsCachedHistory = reusesCachedDisplay || cachedTranscriptModel === model
    session = try opened.response.session.chatSession(serverId: scopedServerId)
    preloadedTranscript = opened.response.transcript
    persistedRuntime = opened.response.runtime
    if let data = opened.data {
      // Queued: the write and its trim run on the cache's own queue.
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

    // Publish established history immediately. First-send setup keeps its
    // model private until setup succeeds so Retry can start cleanly.
    if setupPhases.isEmpty, self.model == nil {
      self.model = model
    }

    if let metadata = persistedRuntime {
      model.applyRuntimeMetadata(modeState: metadata.modes, configOptions: metadata.configOptions)
      if !metadata.configOptions.isEmpty { configOptionsByHarness[harnessId] = metadata.configOptions }
      if let modes = metadata.modes { modeStateByHarness[harnessId] = modes }
      if let supportsGoals = metadata.supportsGoals { supportsGoalsByHarness[harnessId] = supportsGoals }
    }
    // Saved selections are validated when the next prompt resumes the provider.
    didLoadExistingRuntimeConfiguration = true
    didFinishExistingRuntimeConfiguration = true
    updateConfigurationValidationState()

    captureChatCreatedIfNeeded(model: model, harnessId: harnessId)

    // The runtime's options are this chat's own. They refresh this
    // controller's lists but never the shared catalog cache, which New
    // Chat composers read their defaults from.
    if !model.configOptions.isEmpty {
      configOptionsByHarness[harnessId] = model.configOptions
    }

    return model
  }
}
