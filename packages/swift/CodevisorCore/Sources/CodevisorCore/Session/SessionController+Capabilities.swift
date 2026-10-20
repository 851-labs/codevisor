import Foundation
import ACPKit
import os

extension SessionController {
  public var isPrepared: Bool { preparationState == .ready }

  public func prepare() async {
    guard isServerReady else { return }
    guard let serverClient else {
      preparationState = .failed
      return
    }
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

  public func prepareExistingSessionCapabilities() async {
    let harnessId = serverSession?.harnessId ?? selectedHarnessId ?? ""
    guard hasExistingAgentSession, let serverClient, !harnessId.isEmpty else { return }
    let startedAt = ProcessInfo.processInfo.systemUptime
    let target = CapabilityFetchTarget(serverId: project.serverId, cwd: sessionCwdURL.path)
    let savedSelections = existingChatSelections
    do {
      let response = try await serverClient.capabilities(
        cwd: target.cwd,
        harnessId: harnessId,
        configSelections: savedSelections
      )
      guard let capability = response.harnesses.first(where: { $0.harness.id == harnessId }) else {
        existingConfigurationError = "The chat's harness is unavailable."
        updateConfigurationValidationState()
        logExistingChatPhase("capabilities_missing", harnessId: harnessId, startedAt: startedAt)
        return
      }
      let isMachineWideCatalog = savedSelections.isEmpty
      if isMachineWideCatalog {
        configCache.store(capability, forServer: project.serverId)
      }
      configCache.storeSkills(from: [capability], forServer: target.serverId, cwd: target.cwd)
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

  struct CapabilityFetchTarget {
    let serverId: String
    let cwd: String
  }

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
            try await serverClient.capabilities(cwd: cwd).harnesses
          }
        )
      else {
        return false
      }
      guard requestRevision == harnessCapabilityRequestRevision else { return false }
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
    harnesses = available
    for capability in capabilities {
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
