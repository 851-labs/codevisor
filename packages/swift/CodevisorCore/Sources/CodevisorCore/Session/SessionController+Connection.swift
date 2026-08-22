import Foundation
import ACPKit
import os

extension SessionController {
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

    /// How long an unreachable server gets before the wait is treated as a
    /// real failure (error banner with the Restart remedy).
    private static let serverWaitFailureThreshold: Duration = .seconds(10)
    private static let serverWaitRetryInterval: Duration = .milliseconds(500)

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
        if let attempt = connectAttempt {
            await attempt.value
            return
        }
        if let model {
            // A cached chat re-binds without reconnecting. If its turn has
            // been quiet past the stall window, re-verify against durable
            // history on re-entry — "navigate away and back" then heals a
            // stuck view instead of waiting out the next stall cycle.
            await model.reconcileIfStalled()
            return
        }
        guard model == nil, !isConnecting, let serverSession else { return }
        // A worktree draft has no cwd until the worktree is created on first
        // send; connecting now would pin the agent to the project folder.
        guard !wantsNewWorktree || sessionCwdOverride != nil else { return }
        let persistedHarnessId = serverSession.harnessId
        let harnessId = persistedHarnessId.isEmpty ? selectedHarness?.id : persistedHarnessId
        guard let harnessId, !harnessId.isEmpty else { return }
        let harnessName = selectedHarness?.name ?? harnessId
        let attempt = Task { await self.runConnectAttempt(harnessId: harnessId, harnessName: harnessName) }
        connectAttempt = attempt
        await attempt.value
    }

    /// Foreground/network-recovery hook: re-verifies this chat's in-flight
    /// turn against durable server history (see
    /// `SessionModel.reconcileIfInFlight`). Safe to call broadly — idle
    /// chats are a no-op.
    public func reconcileInFlightTurn() async {
        await model?.reconcileIfInFlight()
    }

    private func runConnectAttempt(harnessId: String, harnessName: String) async {
        defer { connectAttempt = nil }
        status = .connecting("Starting \(harnessName)…")
        defer { serverWaitMessage = nil }
        let clock = ContinuousClock()
        let start = clock.now
        while true {
            do {
                model = try await connect(harnessId: harnessId)
                status = .idle
                return
            } catch {
                // View remounts no longer cancel this controller-owned
                // attempt; cancellation now means an explicit supersede
                // (`reconnect()` tearing down a stale attempt) and is
                // lifecycle noise, not a failure. Reset to `.idle` so the
                // successor passes the `!isConnecting` guard — leaving
                // `.connecting` would wedge the controller forever (and
                // `SessionStore` would never evict it, since `.connecting`
                // counts as running).
                guard !isTaskCancellation(error) else {
                    if case .connecting = status { status = .idle }
                    return
                }
                let message = serverErrorMessage(error)
                let elapsed = clock.now - start
                guard message == serverUnreachableErrorMessage,
                    elapsed < Self.serverWaitFailureThreshold
                else {
                    if hasExistingAgentSession {
                        didFinishExistingRuntimeConfiguration = true
                        existingConfigurationError = message
                        updateConfigurationValidationState()
                        if let sessionId = serverSession?.id {
                            finishInitialHistoryLoading(
                                sessionId: sessionId,
                                outcome: "failed"
                            )
                        }
                    }
                    status = .failed(message)
                    return
                }
                serverWaitMessage = "Waiting for the server..."
                try? await Task.sleep(for: Self.serverWaitRetryInterval)
                guard !Task.isCancelled else {
                    if case .connecting = status { status = .idle }
                    return
                }
            }
        }
    }

    /// Selects a different harness (user action) and reconnects.
    public func selectHarness(_ id: String) async {
        guard id != selectedHarnessId else { return }
        let previousHarnessId = selectedHarnessId
        selectedHarnessId = id
        captureHarnessSelected(harnessId: id, previousHarnessId: previousHarnessId)
        if acceptsNewChatDefaults {
            // Start the new harness from its own remembered selections rather
            // than pending edits made under the previous harness.
            seedRememberedConfig()
        }
        composerDefaults?.rememberHarnessSelection(
            in: resolvedComposerDefaultsScope,
            harnessId: id
        )
        if var serverSession {
            serverSession.harnessId = id
            self.serverSession = serverSession
        }
        await reconnect()
    }

    /// Changes the project (new-chat picker) and reconnects.
    public func selectProject(_ project: Project) async {
        guard project.id != self.project.id else { return }
        self.project = project
        // A worktree kept from a reverted first send belongs to the old
        // project; the new project gets its own on the next send.
        sessionCwdOverride = nil
        worktreeName = nil
        if seedFromCachedServerCapabilities() {
            preparationState = .ready
        }
        await reconnect()
    }

    /// Tears down any connection and reconnects — used when the harness or
    /// project changes on the new-chat page.
    public func reconnect() async {
        // Supersede a controller-owned eager connect explicitly: cancel it and
        // wait for it to settle so its failure handling cannot clobber the
        // fresh attempt's status/model below.
        if let attempt = connectAttempt {
            attempt.cancel()
            await attempt.value
        }
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

        // One round-trip replaces the discrete listProjects → upsertProject →
        // listSessions → create/update → transcript sequence: the server
        // ensures both records exist (creating the project only when missing —
        // this controller's copy is a snapshot from when the draft was
        // created, and pushing it used to revert changes made in the
        // meantime, e.g. un-archiving) and returns the first transcript page
        // for an instant paint. Older servers lack the endpoint (nil) and
        // keep the discrete path; loadHistory then fetches the page itself.
        var preloadedTranscript: ServerTranscriptPage?
        let workspaceId: UUID? =
            switch resolvedComposerDefaultsScope {
            case let .workspace(id, _): id
            case .newWorkspace: nil
            }
        if let opened = try await serverClient.openSession(
            session,
            project: project,
            workspaceId: workspaceId,
            transcriptLimit: SessionModel.initialTranscriptPageSize
        ) {
            session = try opened.session.chatSession(serverId: scopedServerId)
            preloadedTranscript = opened.transcript
        } else {
            let remoteProjects = try await serverClient.listProjects()
            if !remoteProjects.contains(where: { UUID(uuidString: $0.id) == project.id }) {
                _ = try await serverClient.upsertProject(project)
            }
            let remoteSession = try await serverClient.upsertSession(
                session,
                workspaceId: workspaceId
            )
            session = try remoteSession.chatSession(serverId: scopedServerId)
        }
        self.serverSession = session

        connectedHarnessId = harnessId
        if session.hasAgentSession, let agentSessionId = session.agentSessionId {
            connectedAgentSessionId = agentSessionId
            onAgentSessionCreated?(agentSessionId)
        }

        // Start the runtime connect without blocking on it: for a resumed
        // thread this can cold-spawn the agent process server-side, which
        // takes multiple seconds on the first open after a server start. The
        // transcript reads straight from the server database and needs no
        // agent, so history loads — and paints — in parallel. The metadata is
        // awaited below, before anything runtime-dependent runs.
        let sessionId = session.id
        let runtimeConnectStartedAt = ProcessInfo.processInfo.systemUptime
        let runtimeConnect: Task<ServerSessionRuntimeMetadata?, Error>? =
            session.hasAgentSession
            ? Task { try await serverClient.connectSession(id: sessionId) }
            : nil

        let transport = ServerSessionTransport(client: serverClient, sessionId: session.id)
        // Paint the persisted selections over cached option definitions while
        // the live runtime validates them. The runtime snapshot below remains
        // authoritative and replaces removed models/options before Send is
        // enabled.
        let initialConfigOptions =
            configOptionsByHarness[harnessId]
            ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
        let model = SessionModel(
            serverTransport: transport,
            sessionId: session.id.uuidString,
            modeState: modeStateByHarness[harnessId],
            configOptions: initialConfigOptions
        )
        model.onTurnEnded = { [weak self, weak model] in
            if let model { self?.captureTurnEnded(model) }
            self?.noteTurnEndedForPlanApproval()
            self?.onTurnEnded?()
        }
        model.onPromptAccepted = { [weak self, weak model] attachmentCount, isQueued in
            self?.configurationAdjustmentMessage = nil
            self?.captureMessageSent(model: model, attachmentCount: attachmentCount, isQueued: isQueued)
        }
        model.onLocalUserMessageAppended = { [weak self] messageID in
            guard self?.pendingUserMessage?.id == messageID else { return }
            self?.pendingUserMessage = nil
        }
        model.onQueuedPromptPromoted = { [weak self] messageID in
            guard let messageID else { return }
            self?.requestUserSendAnimation(for: messageID)
        }
        model.onPlanApprovalChanged = { [weak self] required in
            self?.pendingPlanApproval = required
        }
        // Negotiate the canonical transcript + session-scoped event stream
        // for every server-backed model, including a brand-new empty chat.
        // Skipping this on first send leaves `usesPaginatedHistory` false, so
        // SessionModel falls back to the global compatibility stream. Current
        // servers deliberately exclude session runtime traffic from that
        // stream, which means the answer is persisted but its chunks and
        // terminal event never reach the live UI. Older servers still fall
        // back inside loadHistory() when the transcript endpoint returns 404.
        await model.loadHistoryForInitialDisplay(
            preloaded: preloadedTranscript.map(transport.historyPage(from:))
        )
        pendingPlanApproval = model.pendingPlanApproval
        if loadsExistingHistory {
            finishInitialHistoryLoading(sessionId: session.id, outcome: "ready")
        }
        analyticsUsageBaseline = model.usage

        // Publish the model as soon as history is loaded so an established
        // transcript paints while the agent is still spawning — but never
        // during pre-chat setup. A setup failure must leave no half-connected
        // model behind for Retry to mistake for a ready conversation.
        if setupPhases.isEmpty, self.model == nil {
            self.model = model
        }

        // Capability discovery describes a fresh harness session. A resumed
        // thread can have a different current model and model-specific effort
        // list, so let the loaded runtime replace the generic/cache snapshot.
        // (Stream events that arrive after this still overwrite as usual.)
        do {
            if let runtimeConnect {
                let metadata = try await withTaskCancellationHandler(
                    operation: { try await runtimeConnect.value },
                    onCancel: { runtimeConnect.cancel() }
                )
                if let metadata {
                    if !metadata.configOptions.isEmpty {
                        configOptionsByHarness[harnessId] = metadata.configOptions
                    }
                    if let modes = metadata.modes {
                        modeStateByHarness[harnessId] = modes
                    }
                    if let supportsGoals = metadata.supportsGoals {
                        supportsGoalsByHarness[harnessId] = supportsGoals
                    }
                    // Only a populated snapshot can be compared against: an
                    // empty option list would make every saved key look lost.
                    if !metadata.configOptions.isEmpty {
                        configurationAdjustmentMessage = Self.configurationAdjustmentMessage(
                            saved: session.configSelections,
                            validated: metadata.configOptions
                        )
                    }
                    didLoadExistingRuntimeConfiguration = true
                    model.applyRuntimeMetadata(
                        modeState: metadata.modes,
                        configOptions: metadata.configOptions
                    )
                }
                logExistingChatPhase(
                    "runtime_ready",
                    harnessId: harnessId,
                    startedAt: runtimeConnectStartedAt
                )
            }
            didFinishExistingRuntimeConfiguration = runtimeConnect != nil
            updateConfigurationValidationState()
        } catch {
            logExistingChatPhase(
                "runtime_failed",
                harnessId: harnessId,
                startedAt: runtimeConnectStartedAt
            )
            didFinishExistingRuntimeConfiguration = runtimeConnect != nil
            let message = serverErrorMessage(error)
            existingConfigurationError = message
            updateConfigurationValidationState()
            // History is durable and useful even when the live harness cannot
            // be restored. Keep the loaded model published so reopening a chat
            // never replaces its transcript with an empty error screen.
            model.recordSessionFailure(
                message,
                requiresHarnessAuthentication: message.localizedCaseInsensitiveContains(
                    "signed-in harness account"
                )
            )
            if self.model == nil { self.model = model }
            throw error
        }

        if let pendingModeId {
            await model.setMode(pendingModeId)
        }
        pendingModeId = nil

        // Model changes can replace the model-specific thinking and speed
        // options. Apply dependent selections afterward so a remembered fast
        // tier is available by the time it is restored.
        let pendingConfig = pendingConfigByHarness[harnessId] ?? [:]
        let optionCategories = Dictionary(
            uniqueKeysWithValues: model.configOptions.map { ($0.id, $0.category ?? "") }
        )
        let categoryOrder = [
            SessionConfigOption.Category.model: 0,
            SessionConfigOption.Category.thoughtLevel: 1,
            SessionConfigOption.Category.speed: 2,
        ]
        // Cached options can disappear after an agent update or a model
        // change. Never replay a stale selection the runtime no longer
        // advertises (especially a hidden model-specific control).
        let supportedPendingConfig = pendingConfig.filter { optionCategories[$0.key] != nil }
        let orderedPendingConfig = supportedPendingConfig.sorted { left, right in
            func priority(_ configId: String) -> Int {
                if configId == "model" { return 0 }
                if configId == "speed" { return 2 }
                return categoryOrder[optionCategories[configId] ?? ""] ?? 99
            }
            let leftPriority = priority(left.key)
            let rightPriority = priority(right.key)
            if leftPriority == rightPriority { return left.key < right.key }
            return leftPriority < rightPriority
        }
        for (configId, value) in orderedPendingConfig {
            await model.setConfigOption(configId: configId, value: value)
        }
        pendingConfigByHarness[harnessId] = nil

        captureChatCreatedIfNeeded(model: model, harnessId: harnessId)
        await applyPendingGoal(to: model)

        configCache.store(model.configOptions, forHarness: harnessId, onServer: project.serverId)
        configOptionsByHarness[harnessId] = model.configOptions

        // This connect created the agent session (there was no id to resume
        // when it started), so there is no prior runtime configuration to
        // validate — the just-created runtime is authoritative and its config
        // was written by the replay above. Settle the flags so any later
        // recompute (a mid-connect `session.updated` refresh, a pane remount
        // re-running `prepareExistingSessionCapabilities`) resolves to
        // `.ready` instead of wedging the composer in `.connecting`.
        if runtimeConnect == nil {
            didLoadExistingRuntimeConfiguration = true
            didFinishExistingRuntimeConfiguration = true
            updateConfigurationValidationState()
        }
        return model
    }
}
