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
    guard isServerReady else { return }
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
      await resolveDraftModelAvailabilityIfNeeded()
      await resolveDraftModelSettingsIfNeeded()
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
        await self.resolveDraftModelAvailabilityIfNeeded()
        await self.resolveDraftModelSettingsIfNeeded()
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
    await resolveDraftModelAvailabilityIfNeeded()
    await resolveDraftModelSettingsIfNeeded()
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
      // A fresh-harness inspection supplies option LISTS only. Its
      // `currentValue`s are fresh-session defaults and never stand in for
      // this chat's own values (see `existingChatConfigOptions`), so it
      // is safe to share as catalog data. Only the chat's saved record and
      // its runtime can answer "is this still available".
      configCache.store(capability, forServer: project.serverId)
      applyHarnessCapabilities([capability])
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
    await resolveDraftModelAvailabilityIfNeeded()
    await resolveDraftModelSettingsIfNeeded()
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
    // Capabilities come from the project server and have already been
    // filtered to enabled, ready harnesses. Applying the app's legacy
    // global harness preference here leaks one machine's choice into all
    // the others, so the server snapshot is the sole authority.
    harnesses = available
    for capability in capabilities {
      // Inspection describes a fresh harness and carries its defaults.
      // Existing chats read only option lists from it; once a runtime is
      // connected, its session-specific metadata is authoritative for
      // the lists too.
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
    if acceptsNewChatDefaults {
      applyNewChatSelectionPolicy(capabilities)
    } else if selectedHarnessId == nil {
      selectedHarnessId = harnesses.first?.id
    }
  }
}
