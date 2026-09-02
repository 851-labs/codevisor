import ACPKit
import Foundation

@testable import CodevisorCore

// MARK: - Simulated update surfaces (same file so `private` storage stays
// reachable; a separate extension keeps the class body within size limits).
extension SyncFakeServerClient {

  var appliedUpdates: Int { lock.withLock { _appliedUpdates } }
  var updateInfoChannels: [ServerUpdateChannel] { lock.withLock { _updateInfoChannels } }
  var updateInfoRefreshes: [Bool] { lock.withLock { _updateInfoRefreshes } }
  var appliedChannels: [ServerUpdateChannel] { lock.withLock { _appliedChannels } }

  /// Makes the fake report an available update to `latest`.
  func configureUpdate(
    current: String,
    latest: String,
    installedVersion: String? = nil,
    currentBuildNumber: Int? = nil,
    targetBuildNumber: Int? = nil
  ) {
    lock.withLock {
      currentVersion = current
      latestVersion = latest
      installedVersionAfterUpdate = installedVersion
      self.currentBuildNumber = currentBuildNumber
      self.targetBuildNumber = targetBuildNumber
      applyFailureMessage = nil
      lastApply = nil
      updateApplied = false
      bootId = "boot-before-update"
    }
  }

  /// Makes `applyServerUpdate()` decline as busy (chats still running).
  func configureBusy(_ value: Bool) {
    lock.withLock { _busy = value }
  }

  /// Makes the next apply accept the handoff but fail on the machine:
  /// nothing restarts and updateInfo starts reporting the failure.
  func configureApplyFailure(message: String) {
    lock.withLock { applyFailureMessage = message }
  }

  // MARK: - Simulated harness / plugin inventories

  /// Every mutating update operation in call order, across kinds — the
  /// update-all ordering assertions read this.
  var operationLog: [String] { lock.withLock { _operationLog } }

  func configureHarnesses(_ harnesses: [ServerHarness]) {
    lock.withLock { _harnesses = harnesses }
  }

  func configurePluginUpdates(_ updates: [ServerPluginUpdateStatus]) {
    lock.withLock { _pluginUpdates = updates }
  }

  func updateHarness(id: String) async throws -> ServerHarnessOperationStarted {
    lock.withLock {
      _operationLog.append("harness.update:\(id)")
      return ServerHarnessOperationStarted(accepted: true)
    }
  }

  func listPluginUpdates() async throws -> [ServerPluginUpdateStatus] {
    lock.withLock { _pluginUpdates }
  }

  func preparePluginUpdate(pluginId: String) async throws -> ServerPluginUpdatePlan {
    lock.withLock {
      _operationLog.append("plugin.prepare:\(pluginId)")
      let review = ServerPluginUpdateReview(
        version: "1.1.0",
        setupCommands: [],
        runCommand: "run",
        panes: []
      )
      return ServerPluginUpdatePlan(
        planId: "plan-1",
        pluginId: pluginId,
        name: pluginId,
        resolvedCommit: "abc123",
        expiresAt: "2026-06-30T01:00:00.000Z",
        current: review,
        candidate: review,
        paneChanges: ServerPluginNamedChanges(added: [], removed: [], changed: []),
        toolChanges: ServerPluginNamedChanges(added: [], removed: [], changed: [])
      )
    }
  }

  func applyPluginUpdate(pluginId: String, planId: String) async throws -> ServerPluginSummary {
    lock.withLock {
      _operationLog.append("plugin.apply:\(pluginId)")
      _pluginUpdates = _pluginUpdates.map { status in
        var next = status
        if status.pluginId == pluginId { next.state = .current }
        return next
      }
      return ServerPluginSummary(
        id: pluginId,
        name: pluginId,
        version: "1.1.0",
        source: "managed",
        path: "/tmp/\(pluginId)",
        state: "running"
      )
    }
  }

  // MARK: - Simulated config-plane replica

  func seedSyncEntries(namespace: String, _ entries: [ServerSyncEntry]) {
    lock.withLock { _syncEntries[namespace] = entries }
  }

  func syncEntries(namespace: String) -> [ServerSyncEntry] {
    lock.withLock { _syncEntries[namespace] ?? [] }
  }

  func syncDocument(namespace: String) async throws -> ServerSyncDocument {
    lock.withLock {
      ServerSyncDocument(namespace: namespace, entries: _syncEntries[namespace] ?? [])
    }
  }

  func mergeSyncDocument(
    namespace: String,
    entries: [ServerSyncEntry]
  ) async throws -> ServerSyncDocument {
    lock.withLock {
      let result = SyncClock.merge(_syncEntries[namespace] ?? [], entries)
      _syncEntries[namespace] = result.merged
      if !result.changed.isEmpty {
        _operationLog.append("sync.merge:\(namespace)")
      }
      return ServerSyncDocument(namespace: namespace, entries: result.merged)
    }
  }

  /// Marks a skill this machine's replica wants; reconciles apply it once
  /// the blob arrives.
  func configureWantedSkill(directoryName: String, hash: String) {
    lock.withLock { _wantedSkills.append((directoryName, hash)) }
  }

  func seedSkillBlob(hash: String, _ data: Data) {
    lock.withLock { _skillBlobs[hash] = data }
  }

  func skillBlob(hash: String) -> Data? {
    lock.withLock { _skillBlobs[hash] }
  }

  var appliedSkills: [String] {
    lock.withLock {
      _wantedSkills.filter { _appliedSkillHashes.contains($0.hash) }.map(\.directoryName)
    }
  }

  func reconcileSkillsSync() async throws -> ServerSkillsSyncStatus {
    lock.withLock {
      var applied: [String] = []
      var missing: [ServerSkillsSyncMissingBlob] = []
      for skill in _wantedSkills {
        if _appliedSkillHashes.contains(skill.hash) { continue }
        if _skillBlobs[skill.hash] != nil {
          _appliedSkillHashes.insert(skill.hash)
          applied.append(skill.directoryName)
        } else {
          missing.append(
            ServerSkillsSyncMissingBlob(
              directoryName: skill.directoryName,
              hash: skill.hash
            ))
        }
      }
      _operationLog.append("skills.reconcile")
      return ServerSkillsSyncStatus(
        published: [],
        applied: applied,
        removed: [],
        missingBlobs: missing
      )
    }
  }

  func syncBlob(id: String) async throws -> Data {
    try lock.withLock {
      guard let data = _skillBlobs[id] else {
        throw CodevisorServerClientError.invalidResponse
      }
      return data
    }
  }

  func putSyncBlob(id: String, bytes: Data) async throws {
    lock.withLock { _skillBlobs[id] = bytes }
  }

  func reconcileMcpsSync() async throws -> ServerMcpSyncStatus {
    lock.withLock {
      _operationLog.append("mcps.reconcile")
      return ServerMcpSyncStatus(published: [], applied: [], removed: [])
    }
  }

  func publishAccountsSync() async throws {
    lock.withLock { _operationLog.append("accounts.publish") }
  }

  func reconcileHarnessesSync() async throws -> ServerHarnessSyncStatus {
    lock.withLock {
      _operationLog.append("harnesses.reconcile")
      return ServerHarnessSyncStatus(
        published: [], applied: _harnessesSyncApplied, removed: [], installing: [],
        blocked: [])
    }
  }

  func reconcilePluginsSync() async throws -> ServerPluginSyncStatus {
    lock.withLock {
      _operationLog.append("plugins.reconcile")
      return ServerPluginSyncStatus(
        published: [], applied: [], removed: [], installed: [], blocked: [])
    }
  }

  func setSyncParticipation(enabled: Bool) async throws -> ServerSyncParticipation {
    lock.withLock { _operationLog.append("sync.participation:\(enabled)") }
    return ServerSyncParticipation(enabled: enabled)
  }

  func health() async throws -> ServerHealth {
    lock.withLock {
      ServerHealth(
        ok: true,
        version: currentVersion,
        database: "ready",
        bootId: bootId,
        buildNumber: currentBuildNumber
      )
    }
  }
  func configureInfoId(_ id: String) {
    lock.withLock { _infoId = id }
  }

  func configureInfoCloudDeviceId(_ deviceId: String?) {
    lock.withLock { _infoCloudDeviceId = deviceId }
  }

  func info() async throws -> ServerInfo {
    let (version, id): (String, String) = try lock.withLock {
      if downtimeRemaining > 0 {
        downtimeRemaining -= 1
        throw ServerDownError()
      }
      return (currentVersion, _infoId)
    }
    let cloudDeviceId = lock.withLock { _infoCloudDeviceId }
    var info = ServerInfo(
      id: id, name: "Local", kind: "local", version: version, platform: "darwin", bindHost: "127.0.0.1")
    info.cloudDeviceId = cloudDeviceId
    return info
  }
  func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
    lock.withLock {
      _updateInfoChannels.append(channel)
      _updateInfoRefreshes.append(refresh)
      return ServerUpdateInfo(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        updateAvailable: !updateApplied && currentVersion != latestVersion,
        channel: channel.rawValue,
        checkedAt: nil,
        migrationState: "idle",
        currentBuildNumber: currentBuildNumber,
        latestBuildNumber: targetBuildNumber,
        lastApply: lastApply
      )
    }
  }
  func applyServerUpdate(channel: ServerUpdateChannel) async throws -> ServerUpdateApplied {
    lock.withLock {
      _appliedChannels.append(channel)
      _appliedUpdates += 1
      if _busy {
        return ServerUpdateApplied(accepted: false, targetVersion: currentVersion, reason: "busy")
      }
      guard currentVersion != latestVersion else {
        return ServerUpdateApplied(accepted: false, targetVersion: currentVersion)
      }
      if let applyFailureMessage {
        // The handoff was accepted but the machine's unattended
        // install failed: nothing restarts, and the failure
        // surfaces through updateInfo's lastApply.
        lastApply = ServerUpdateApplyState(
          state: "failed",
          message: applyFailureMessage,
          targetVersion: latestVersion,
          at: "2026-06-30T00:00:01.000Z"
        )
        return ServerUpdateApplied(
          accepted: true,
          targetVersion: latestVersion,
          targetBuildNumber: targetBuildNumber
        )
      }
      _operationLog.append("server.apply")
      // The server restarts: unreachable for a few probes, then back on
      // the new version.
      downtimeRemaining = 3
      let targetVersion = latestVersion
      currentVersion = installedVersionAfterUpdate ?? latestVersion
      if let targetBuildNumber { currentBuildNumber = targetBuildNumber }
      updateApplied = true
      bootId = "boot-after-update"
      return ServerUpdateApplied(
        accepted: true,
        targetVersion: targetVersion,
        targetBuildNumber: targetBuildNumber
      )
    }
  }
  func issuePairingToken() async throws -> ServerPairingToken {
    ServerPairingToken(token: "hm_test", createdAt: "2026-06-30T00:00:00.000Z")
  }
  func capabilities(cwd: String) async throws -> ServerCapabilities {
    if let capabilitiesHandler { return try await capabilitiesHandler(cwd) }
    return ServerCapabilities(harnesses: [])
  }
  func capabilities(
    cwd: String,
    harnessId: String,
    configSelections: [String: String]
  ) async throws -> ServerCapabilities {
    if let resolvedCapabilitiesHandler {
      return try await resolvedCapabilitiesHandler(cwd, harnessId, configSelections)
    }
    let response = try await capabilities(cwd: cwd)
    return ServerCapabilities(
      harnesses: response.harnesses.filter { $0.harness.id == harnessId }
    )
  }
  func listHarnesses() async throws -> [ServerHarness] { lock.withLock { _harnesses } }
  func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
  func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
  func deleteProject(id: UUID) async throws {}
  func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
  func upsertSession(_ session: ChatSession) async throws -> ServerSession {
    lock.withLock {
      guard
        let index = _sessions.firstIndex(where: {
          UUID(uuidString: $0.id) == session.id
        })
      else { fatalError("Missing fake session") }
      return _sessions[index]
    }
  }
  func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
    lock.withLock {
      guard
        let index = _sessions.firstIndex(where: {
          UUID(uuidString: $0.id) == session.id
        })
      else { fatalError("Missing fake session") }
      _sessions[index].workspaceId = workspaceId?.uuidString
      if let workspaceId, _panes != nil,
        _panes?.contains(where: {
          $0.resourceKind == "session"
            && $0.resourceId?.caseInsensitiveCompare(session.id.uuidString) == .orderedSame
        }) == false
      {
        _panes?.append(
          ServerWorkspacePane(
            id: session.id.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "chat",
            title: _sessions[index].title,
            resourceKind: "session",
            resourceId: session.id.uuidString,
            createdAt: _sessions[index].createdAt
          )
        )
      }
      return _sessions[index]
    }
  }
  func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
  func deleteSession(id: UUID) async throws {}
  func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
    ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
  }
  func cancelSession(id: UUID) async throws {}
  func setSessionMode(id: UUID, modeId: String) async throws {}
  func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
