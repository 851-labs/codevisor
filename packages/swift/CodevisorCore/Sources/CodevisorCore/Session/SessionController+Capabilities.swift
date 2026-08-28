import Foundation
import ACPKit
import os

extension SessionController {
    public var isPrepared: Bool { preparationState == .ready }

    // MARK: - Actions

    /// Loads the harness list for the picker from the server (cached
    /// capabilities first for instant display, then a live refresh). For a new
    /// chat the list honors the user's enabled set (falling back to all ready
    /// harnesses if they've disabled everything); a resumed session always
    /// keeps its own harness.
    public func prepare() async {
        guard let serverClient else {
            preparationState = .failed
            return
        }
        // The machine and its client are one snapshot: a retarget that lands
        // mid-flight must not let this fetch (bound to the OLD machine's
        // client) store its response under the NEW machine's cache key.
        let target = CapabilityFetchTarget(
            serverId: project.serverId,
            cwd: capabilityCwd
        )
        if seedFromCachedServerCapabilities() {
            preparationState = .ready
            await resolveAutomaticSelectionIfNeeded()
            guard
                configCache.needsCapabilityRevalidation(
                    forServer: target.serverId,
                    cwd: target.cwd
                )
            else { return }
            let requestRevision = beginHarnessCapabilityRefresh()
            Task {
                _ = await self.prepareFromServerCapabilities(
                    serverClient,
                    target: target,
                    requestRevision: requestRevision
                )
                await self.resolveAutomaticSelectionIfNeeded()
            }
            return
        }
        // No usable models cached, but a persisted sign-in-required list is
        // still a settled answer — render it while the live fetch runs.
        preparationState =
            configCache.signInRequired(forServer: project.serverId).isEmpty ? .loading : .ready
        let requestRevision = beginHarnessCapabilityRefresh()
        _ = await prepareFromServerCapabilities(
            serverClient,
            target: target,
            requestRevision: requestRevision
        )
        await resolveAutomaticSelectionIfNeeded()
    }

    /// Refreshes only the harness used by a resumed chat. This runs beside
    /// transcript/runtime connection and never gates the first history paint.
    /// The live resumed-session metadata remains authoritative; this snapshot
    /// supplies fresh picker definitions and the compatibility fallback for
    /// servers that do not yet return runtime metadata from `/connect`.
    public func prepareExistingSessionCapabilities() async {
        let harnessId = serverSession?.harnessId ?? selectedHarnessId ?? ""
        guard hasExistingAgentSession, let serverClient, !harnessId.isEmpty else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await serverClient.capabilities(
                cwd: sessionCwdURL.path,
                harnessId: harnessId
            )
            guard let capability = response.harnesses.first(where: { $0.harness.id == harnessId }) else {
                existingConfigurationError = "The chat's harness is unavailable."
                updateConfigurationValidationState()
                logExistingChatPhase("capabilities_missing", harnessId: harnessId, startedAt: startedAt)
                return
            }
            var validatedCapability = capability
            validatedCapability.configOptions = Self.configurationOptions(
                restoring: serverSession?.configSelections,
                from: capability.configOptions
            )
            // Deliberately NOT deriving `configurationAdjustmentMessage` here.
            // This is a throwaway fresh-harness inspection: it runs under the
            // harness's *active* account rather than the chat's bound one, its
            // model list is a best-effort race that yields an empty list on
            // timeout, and its effort/speed lists are derived from the
            // inspection's own default model. Any of those makes the chat's
            // saved selection look missing, and because this call beats the
            // runtime connect (which can cold-spawn the agent), the false
            // claim was what the user actually read. Only the resumed
            // runtime's own snapshot can answer "is this still available".
            configCache.store(validatedCapability, forServer: project.serverId)
            applyHarnessCapabilities([validatedCapability])
            // A late generic inspection must not leave its fresh-session
            // defaults in the fast cache after the actual resumed runtime won.
            if let model, let connectedHarnessId {
                configCache.store(
                    model.configOptions,
                    forHarness: connectedHarnessId,
                    onServer: project.serverId
                )
            }
            didLoadExistingHarnessCapabilities = true
            existingConfigurationError = nil
            updateConfigurationValidationState()
            logExistingChatPhase("capabilities_ready", harnessId: harnessId, startedAt: startedAt)
        } catch {
            existingConfigurationError = serverErrorMessage(error)
            updateConfigurationValidationState()
            logExistingChatPhase("capabilities_failed", harnessId: harnessId, startedAt: startedAt)
        }
    }

    public func retryExistingSessionCapabilities() async {
        didLoadExistingHarnessCapabilities = false
        existingConfigurationError = nil
        updateConfigurationValidationState()
        await prepareExistingSessionCapabilities()
    }

    /// Reloads the authoritative harness catalog after authentication or
    /// enablement changes. Unlike `prepare()`, this deliberately bypasses the
    /// stale cache because the caller is responding to an explicit mutation.
    public func refreshHarnessCapabilities() async {
        guard let serverClient else {
            preparationState = .failed
            isRefreshingHarnessCapabilities = false
            return
        }
        let requestRevision = beginHarnessCapabilityRefresh()
        _ = await prepareFromServerCapabilities(
            serverClient,
            target: CapabilityFetchTarget(
                serverId: project.serverId,
                cwd: capabilityCwd
            ),
            requestRevision: requestRevision,
            force: true
        )
        await resolveAutomaticSelectionIfNeeded()
    }

    /// Marks a mounted draft stale after authentication, account, enablement,
    /// or discovery changes. Keep the last usable picker mounted while the
    /// replacement loads; only a draft with no snapshot needs blocking UI.
    /// Connected sessions keep their runtime-owned configuration.
    public func invalidateHarnessCapabilities() {
        harnessCapabilityRequestRevision &+= 1
        guard model == nil else { return }
        modelConfigurationResolutionRevision &+= 1
        isResolvingModelConfiguration = false
        isRefreshingHarnessCapabilities = true
        preparationState =
            harnesses.isEmpty && configCache.signInRequired(forServer: project.serverId).isEmpty
            ? .loading : .ready
    }

    /// Whether the draft has a settled, RENDERABLE answer for its machine's
    /// catalog: some harness with inspected options, or — for a machine with
    /// nothing usable at all — the persisted sign-in-required list ("Select
    /// a harness" plus sign-in rows). Either holds steady while a refresh
    /// runs. A provisional seed (harnesses known, options not inspected yet)
    /// is NOT settled: its models are still coming, so the spinner is honest.
    var hasSettledCatalogKnowledge: Bool {
        if harnesses.isEmpty {
            return !configCache.signInRequired(forServer: project.serverId).isEmpty
        }
        return harnesses.contains { !(configOptionsByHarness[$0.id] ?? []).isEmpty }
    }

    static func configurationAdjustmentMessage(
        saved: [String: String]?,
        validated: [SessionConfigOption]
    ) -> String? {
        guard let saved, !saved.isEmpty else { return nil }
        // An option the snapshot does not advertise at all is not evidence of
        // loss: several (`speed`, model-specific effort tiers) exist only for
        // certain models, so their absence is routine. Only an option that is
        // still present AND now reports a different value means the saved
        // selection could not be restored.
        let changed = saved.compactMap { configId, previousValue -> (String, SessionConfigOption)? in
            guard let option = validated.first(where: { $0.id == configId }),
                option.currentValue != previousValue
            else { return nil }
            return (previousValue, option)
        }
        guard !changed.isEmpty else { return nil }
        if let (previousValue, model) = changed.first(where: {
            $0.1.category == SessionConfigOption.Category.model || $0.1.id == "model"
        }) {
            // A different current value does not prove the saved model was
            // withdrawn. Providers can advertise a model while transiently
            // rejecting its automatic restore; the picker may successfully
            // apply that same value moments later.
            if let previous = model.options.first(where: { $0.value == previousValue }) {
                return "\(previous.name) couldn’t be restored. Using \(model.currentName)."
            }
            return "\(previousValue) is no longer available. Using \(model.currentName)."
        }
        let hasUnavailableValue = changed.contains { previousValue, option in
            !option.options.contains { $0.value == previousValue }
        }
        if !hasUnavailableValue {
            return "Some saved settings couldn’t be restored. Current harness values are being used."
        }
        return "Some saved settings are no longer available. Current harness defaults are being used."
    }

    /// A capability inspection represents a fresh session, so its
    /// `currentValue`s are defaults. Preserve persisted values only when the
    /// freshly inspected option list still advertises them; removed values
    /// deliberately fall back to the harness default.
    private static func configurationOptions(
        restoring saved: [String: String]?,
        from inspected: [SessionConfigOption]
    ) -> [SessionConfigOption] {
        guard let saved, !saved.isEmpty else { return inspected }
        var restored = inspected
        for (configId, previousValue) in saved {
            guard let index = restored.firstIndex(where: { $0.id == configId }),
                restored[index].options.contains(where: { $0.value == previousValue })
            else { continue }
            restored[index].currentValue = previousValue
        }
        return restored
    }

    func finishInitialHistoryLoading(sessionId: UUID, outcome: String) {
        guard isLoadingInitialHistory else { return }
        let startedAt = initialHistoryLoadStartedAt ?? ProcessInfo.processInfo.systemUptime
        isLoadingInitialHistory = false
        initialHistoryLoadStartedAt = nil
        let durationMs = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
        Log.session.info(
            "existing_chat_history phase=\(outcome, privacy: .public) session_id=\(sessionId.uuidString, privacy: .public) duration_ms=\(durationMs)"
        )
    }

    func logExistingChatPhase(
        _ phase: String,
        harnessId: String,
        startedAt: TimeInterval
    ) {
        let durationMs = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded())
        Log.session.info(
            "existing_chat_load phase=\(phase, privacy: .public) harness_id=\(harnessId, privacy: .public) duration_ms=\(durationMs)"
        )
    }

    private func beginHarnessCapabilityRefresh() -> UInt64 {
        harnessCapabilityRequestRevision &+= 1
        isRefreshingHarnessCapabilities = true
        return harnessCapabilityRequestRevision
    }

    /// The machine/directory pair a capability fetch is bound to, captured
    /// together with the machine's client BEFORE any suspension. Re-reading
    /// `project` after an await raced retargets: a fetch against machine A's
    /// client stored A's catalog under machine B's cache key, permanently
    /// showing B another machine's models.
    struct CapabilityFetchTarget {
        let serverId: String
        let cwd: String
    }

    /// A project-less iOS draft can still inspect its machine's harnesses.
    /// Sending an empty cwd asks the server to use its own temporary directory
    /// instead of treating the sentinel's `/` path as a real workspace.
    var capabilityCwd: String {
        project.isRunTargetPlaceholder ? "" : project.folderURL.path
    }

    @discardableResult
    private func prepareFromServerCapabilities(
        _ serverClient: any CodevisorServerClienting,
        target: CapabilityFetchTarget,
        requestRevision: UInt64,
        force: Bool = false
    ) async -> Bool {
        do {
            let cwd = target.cwd
            guard
                let capabilities = try await configCache.revalidateCapabilities(
                    forServer: target.serverId,
                    cwd: cwd,
                    force: force,
                    fetch: {
                        // The full response: the cache splits usable
                        // capabilities from sign-in-pending harnesses itself.
                        try await serverClient.capabilities(cwd: cwd).harnesses
                    }
                )
            else {
                return false
            }
            guard requestRevision == harnessCapabilityRequestRevision else { return false }
            // Belt over the revision guard: never apply a snapshot fetched
            // for a machine this draft no longer targets.
            guard project.serverId == target.serverId else { return false }
            applyHarnessCapabilities(capabilities)
            preparationState = .ready
            isRefreshingHarnessCapabilities = false
            return true
        } catch {
            guard requestRevision == harnessCapabilityRequestRevision else { return false }
            Log.session.error("capability fetch failed: \(String(describing: error), privacy: .public)")
            if harnesses.isEmpty {
                preparationState = .failed
            }
            isRefreshingHarnessCapabilities = false
            return false
        }
    }

    @discardableResult
    func seedFromCachedServerCapabilities() -> Bool {
        guard serverClient != nil else { return false }
        let cached = configCache.capabilities(forServer: project.serverId).filter { capability in
            capability.harness.enabled && capability.harness.isReady
        }
        guard !cached.isEmpty else { return false }
        applyHarnessCapabilities(cached)
        return true
    }

    private func applyHarnessCapabilities(_ capabilities: [ServerHarnessCapability]) {
        let available = capabilities.map(\.harness)
        let isNewChat = resumeAgentSessionId?.isEmpty != false
        // Capabilities come from the project server and have already been
        // filtered to enabled, ready harnesses. Applying the app's legacy
        // global harness preference here leaks one machine's choice into all
        // the others, so the server snapshot is the sole authority.
        harnesses = available
        for capability in capabilities {
            // Inspection describes a fresh harness and carries its defaults.
            // Once a runtime is connected, its session-specific metadata is
            // authoritative: a late capability refresh must not replace a
            // resumed chat's persisted model/effort/speed with fresh-session
            // defaults (for example, changing Codex `high` back to `low`).
            let isConnectedHarness =
                model != nil
                && connectedHarnessId == capability.harness.id
            if !isConnectedHarness {
                configOptionsByHarness[capability.harness.id] = capability.configOptions
            }
            if let modes = capability.modes {
                modeStateByHarness[capability.harness.id] = modes
            }
            supportsGoalsByHarness[capability.harness.id] = capability.supportsGoals ?? false
        }
        if isNewChat {
            applyNewChatSelectionPolicy(capabilities)
        } else if selectedHarnessId == nil {
            selectedHarnessId = harnesses.first?.id
        }
        ensureDefaultModelSelection()
    }
}
