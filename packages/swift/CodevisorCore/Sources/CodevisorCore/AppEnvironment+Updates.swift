import Foundation

extension AppEnvironment {
  public var defaultComposerServerId: String {
    if let remembered = composerDefaults.lastNewWorkspaceServerId,
      let canonical = machines.canonicalComposerMachineId(for: remembered),
      !machines.isSandbox(canonical)
    {
      return canonical
    }
    return machines.chatMachines.first?.id ?? CodevisorMachine.local.id
  }

  public func prepareMachine(_ serverId: String) async {
    await machines.prepareMachine(serverId)
  }

  public func prepareAllMachines() async {
    await machines.prepareAllMachines()
  }

  func noteMachineConnected(_ machineId: String) {
    checkHarnessNotices(onServer: machineId)
    Task { await bots.refresh(serverId: machineId) }
    Task {
      await configSync.synchronizeMachine(machineId)
      if machineId == CodevisorMachine.local.id {
        await seedHarnessCatalogIfNeeded(from: machineId)
      }
    }
    if machineId == CodevisorMachine.local.id { syncLocalServerDirectPaths() }
  }

  func checkHarnessNotices(onServer serverId: String) {
    #if os(macOS)
      let client = machines.client(for: serverId)
      Task { await harnessNotices.check(client) }
    #endif
  }

  func showHarnessNotice(_ notice: ServerHarnessNotice) {
    #if os(macOS)
      harnessNotices.show([notice])
    #endif
  }

  static let harnessCatalogSeedKey = "harnessCatalogSeed.v1"

  func seedHarnessCatalogIfNeeded(from serverId: String) async {
    guard settings.hasCompletedOnboarding,
      machines.persistenceStore.loadData(forKey: Self.harnessCatalogSeedKey) == nil
    else { return }
    if HarnessFleet.settings(configSync, includingUninstalled: true).isEmpty {
      guard let harnesses = try? await harnessService(for: serverId).allHarnesses() else { return }
      HarnessFleet.seed(from: harnesses, in: configSync)
    }
    try? machines.persistenceStore.saveData(Data([1]), forKey: Self.harnessCatalogSeedKey)
  }

  public func harnessService(for serverId: String) -> any HarnessServicing {
    harnessServiceOverride ?? ServerHarnessService(client: machines.client(for: serverId))
  }

  public func harnessCatalogRevision(for serverId: String) -> UInt64 {
    harnessCatalogRevisions[serverId, default: 0]
  }

  public func harnessCatalogDidChange(onServer serverId: String) {
    configCache.invalidateCapabilities(forServer: serverId)
    harnessCatalogRevisions[serverId, default: 0] &+= 1
  }

  public func refreshHarnessAuthentication(
    onServer serverId: String
  ) async throws -> [ServerHarness] {
    let refreshed = try await machines.client(for: serverId).refreshHarnessAuth()
    harnessCatalogDidChange(onServer: serverId)
    return refreshed
  }

  public func settleHarnessAuthentication(onServer serverId: String) async throws -> [ServerHarness] {
    let settled = try await machines.client(for: serverId).settleHarnessAuth()
    harnessCatalogDidChange(onServer: serverId)
    return settled
  }

  public func refreshHarnessAuthentication(
    harnessId: String,
    onServer serverId: String
  ) async throws -> ServerHarness {
    let refreshed = try await machines.client(for: serverId).refreshHarnessAuth(harnessId: harnessId)
    harnessCatalogDidChange(onServer: serverId)
    return refreshed
  }

  public func syncClientPreferences(_ keys: Set<String>, preferences: ClientPreferences = .shared) {
    let sync = ClientPreferenceSync(preferences: preferences, configSync: configSync, keys: keys)
    clientPreferenceSync = sync
    sync.start()
  }

  func applySyncedNamespace(_ namespace: String) {
    if namespace == "settings" { applySyncedSettings() }
    if namespace == ClientPreferenceSync.namespace { clientPreferenceSync?.adoptSyncedValues() }
    if namespace == ConfigSync.skillsNamespace { Task { await configSync.synchronizeSkills() } }
    if namespace == "harnesses" || namespace == "harness-accounts"
      || namespace == "harness-credentials" || namespace == "harness-shared-accounts"
    {
      for machine in machines.allMachines {
        harnessCatalogDidChange(onServer: machine.id)
      }
    }
  }

  func applyBootSyncState() {
    applySyncedSettings()
  }

  public func sessionImporter(for serverId: String) -> SessionImporter {
    SessionImporter(harnessService: harnessService(for: serverId))
  }

  public var isUpdateInProgress: Bool {
    appUpdate.isUpdating
  }

  func noteHarnessLifecycle(onServer serverId: String) {
    harnessCatalogDidChange(onServer: serverId)
    updateCenter.noteHarnessLifecycleChanged(onServer: serverId)
  }

  public func setAlphaUpdatesEnabled(_ enabled: Bool) {
    settings.setAlphaUpdatesEnabled(enabled)
    appUpdate.setAllowsAlphaUpdates(enabled)
    machines.serverUpdateChannel = enabled ? .alpha : .stable
    reportReleaseChannel(alpha: enabled)
    configSync.set(
      namespace: "settings",
      key: "updateChannel",
      value: .string(enabled ? "alpha" : "stable")
    )
    Task { [machines] in
      for machine in machines.allMachines {
        await machines.refreshStatus(for: machine.id)
      }
      await machines.refreshServerUpdates(force: true)
    }
  }

  func applySyncedSettings() {
    guard
      case let .string(channel)? = configSync.value(
        namespace: "settings",
        key: "updateChannel"
      )
    else { return }
    let alpha = channel == "alpha"
    guard alpha != settings.alphaUpdatesEnabled else { return }
    settings.setAlphaUpdatesEnabled(alpha)
    appUpdate.setAllowsAlphaUpdates(alpha)
    machines.serverUpdateChannel = alpha ? .alpha : .stable
    reportReleaseChannel(alpha: alpha)
  }

  func reportReleaseChannel(alpha: Bool) {
    CloudReleaseChannel.shared.isAlpha = alpha || CodevisorAppVariant.isDevelopment
  }

  public func recommendedProjects(
    serverId: String,
    limit: Int = 12
  ) async throws -> [ProjectRecommendation] {
    let records = try await machines.client(for: serverId).projectRecommendations(limit: limit)
    let recommendations = records.map { record in
      ProjectRecommendation(
        folderURL: URL(fileURLWithPath: record.path),
        name: record.name,
        sessionCount: record.sessionCount,
        lastActivity: record.lastActivity.flatMap(Self.recommendationDate(from:))
      )
    }
    projectRecommendationCache[serverId] = recommendations
    return recommendations
  }

  public func cachedRecommendedProjects(serverId: String) -> [ProjectRecommendation]? {
    projectRecommendationCache[serverId]
  }

  private static func recommendationDate(from string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
  }

  public func findImportableSessions(
    for folderURL: URL,
    serverId: String
  ) async -> [ImportedSession] {
    let folderPath = folderURL.standardizedFileURL.path
    let imported = await sessionImporter(for: serverId).fetchAll()
    let knownSessions = projectList.sessions
    return await Task.detached {
      imported.filter { item in
        let matchesFolder = URL(fileURLWithPath: item.info.cwd).standardizedFileURL.path == folderPath
        let alreadyKnown = knownSessions.contains {
          $0.serverId == serverId
            && $0.harnessId == item.harnessId
            && $0.agentSessionId == item.info.sessionId
        }
        return matchesFolder && !alreadyKnown
      }
    }.value
  }
}
