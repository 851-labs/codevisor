import Foundation
import Observation
import ACPKit

@MainActor
@Observable
public final class AppEnvironment {
  public let projectList: ProjectListModel
  public let attentionCoordinator: SessionAttentionCoordinator
  public let configCache: ConfigOptionCache
  public let composerDefaults: ComposerDefaultsStore
  public let composerDrafts: ComposerDraftStore
  public let settings: AppSettingsModel
  public let machines: MachineController
  public let cloud: CloudAccountController
  public let directMachineAdoption: DirectMachineCloudAdoption
  public let pluginAccess: PluginAccessController
  public let localServer: (any LocalServerControlling)?
  public let appUpdate: AppUpdateModel
  public let updateCenter: UpdateCenter
  public let configSync: ConfigSync
  public let bots: BotListModel
  public let botSections: BotSectionStore
  public let sandboxSettings = SandboxSettingsModel()

  @ObservationIgnored var projectRecommendationCache: [String: [ProjectRecommendation]] = [:]
  @ObservationIgnored var failedDialRefresh = CloudRosterRefreshThrottle()
  @ObservationIgnored public var onSessionStateChanged: ((ChatSession, Int?) -> Void)?
  @ObservationIgnored var clientPreferenceSync: ClientPreferenceSync?
  @ObservationIgnored let harnessNotices = HarnessNoticeCenter()
  public let paneGroups: any PaneGroupRepository
  public let workspaces: any WorkspaceRepository
  public let navigationStore: NavigationStore
  public let transcriptCache: TranscriptPageCache?
  public let workspaceSync: WorkspaceSyncModel
  let harnessServiceOverride: (any HarnessServicing)?
  var harnessCatalogRevisions: [String: UInt64] = [:]
  var pluginStateRevisions: [String: UInt64] = [:]
  var mcpStateRevisions: [String: UInt64] = [:]
  var pluginUpdateRevisions: [String: UInt64] = [:]
  private let clientDataResetter: (any ClientDataResetting)?
  public let now: @MainActor () -> Date

  public init(
    navigationPersistence: any PersistenceStore = InMemoryStore(),
    launchSnapshot: ClientLaunchSnapshot? = nil,
    transcriptCache: TranscriptPageCache? = nil,
    configCache: ConfigOptionCache,
    composerDefaults: ComposerDefaultsStore? = nil,
    composerDrafts: ComposerDraftStore? = nil,
    settings: AppSettingsModel,
    machineStore: any PersistenceStore = InMemoryStore(),
    cloudCredentialStore: (any CloudCredentialStore)? = nil,
    paneGroups: any PaneGroupRepository = DefaultPaneGroupRepository(store: InMemoryStore()),
    localServer: (any LocalServerControlling)? = nil,
    appUpdate: AppUpdateModel? = nil,
    harnessService: (any HarnessServicing)? = nil,
    machineClientFactory: MachineController.ClientFactory? = nil,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.now = now
    self.harnessServiceOverride = harnessService
    self.paneGroups = paneGroups
    self.transcriptCache = transcriptCache
    NavigationStoreMigration.runIfNeeded(
      store: navigationPersistence, machineIds: [CodevisorMachine.local.id])
    let navigationStore = NavigationStore(store: navigationPersistence, launchSnapshot: launchSnapshot)
    self.navigationStore = navigationStore
    let workspaces = ProjectedWorkspaceRepository(store: navigationStore)
    self.workspaces = workspaces
    self.appUpdate =
      appUpdate
      ?? AppUpdateModel(
        currentVersion: AppUpdateModel.bundleVersion(),
        currentBuildNumber: AppUpdateModel.bundleBuildNumber(),
        allowsAlphaUpdates: settings.alphaUpdatesEnabled
      )
    self.projectList = ProjectListModel()
    projectList.navigationStore = navigationStore
    self.attentionCoordinator = SessionAttentionCoordinator(projectList: projectList)
    self.workspaceSync = WorkspaceSyncModel(repository: workspaces, projectList: projectList)
    workspaceSync.navigationStore = navigationStore
    navigationStore.attach(projectList: projectList, repository: workspaces)
    self.configCache = configCache
    self.composerDefaults = composerDefaults ?? ComposerDefaultsStore(store: InMemoryStore())
    self.composerDrafts = composerDrafts ?? ComposerDraftStore(store: InMemoryStore())
    self.settings = settings
    self.localServer = localServer
    self.clientDataResetter = machineStore as? any ClientDataResetting
    self.machines = MachineController(
      store: machineStore,
      projectList: projectList,
      workspaceSync: workspaceSync,
      localServer: localServer,
      clientFactory: machineClientFactory
    )
    updateCenter = UpdateCenter(machines: machines, appUpdate: self.appUpdate, now: now)
    configSync = ConfigSync(machines: machines)
    bots = BotListModel(machines: machines)
    botSections = BotSectionStore(configSync: configSync)
    self.cloud = CloudAccountController(
      credentialStore: cloudCredentialStore ?? InMemoryCloudCredentialStore()
    )
    self.pluginAccess = PluginAccessController(cloud: cloud, store: machineStore)
    self.directMachineAdoption = DirectMachineCloudAdoption(store: machineStore)
    configureServices()
  }

  private func configureServices() {
    updateCenter.listedHarnessIds = { [configSync] in
      guard configSync.hasSnapshot(namespace: "harnesses") else { return nil }
      return Set(HarnessFleet.settings(configSync).map(\.id))
    }
    #if os(iOS)
      updateCenter.reviewPluginUpdate = { [pluginAccess] _, plan in
        try await pluginAccess.requireEligible(pluginId: plan.pluginId, ageRating: plan.candidate.ageRating)
      }
    #endif
    machines.cloudProvider = cloud
    if localServer != nil {
      cloud.localServerClient = machines.client(for: CodevisorMachine.local.id)
    }
    cloud.onLocalMachineRegistrationResolved = { [weak self] deviceId in
      self?.machines.adoptLocalCloudIdentity(deviceId: deviceId)
    }
    cloud.onSignedOut = { [weak self] in
      self?.machines.handleCloudAccountSignedOut()
    }
    cloud.directPaths.onPipeUp = { [weak self] deviceId in
      self?.machines.cloudMachineBecameReachable(deviceId: deviceId)
    }
    applyLaunchLocalNetworkAccess()
    wireCloudRefreshAndAdoption()
    projectList.showsImportedSessions = settings.importExternalSessions
    machines.serverUpdateChannel = settings.alphaUpdatesEnabled ? .alpha : .stable
    reportReleaseChannel(alpha: settings.alphaUpdatesEnabled)
    wireHarnessAndConfigurationSync()
    applyBootSyncState()
    wireResourceChangeCallbacks()
    backfillComposerDefaultsFromPersistedState()
    if self.composerDefaults.lastNewWorkspaceServerId == nil,
      machines.machine(for: machines.selectedMachineId) != nil
    {
      self.composerDefaults.rememberNewWorkspaceServer(serverId: machines.selectedMachineId)
    }
  }

  private func wireCloudRefreshAndAdoption() {
    cloud.directPaths.onDialFailed = { [weak self] _ in
      guard let self, self.failedDialRefresh.allowsRefresh(at: .now) else { return }
      Task { await self.cloud.refreshCloudMachines() }
    }
    cloud.onMachinesRefreshed = { [weak self] in
      if let access = self?.pluginAccess { Task { try? await access.syncConsent() } }
      self?.machines.reconcileCloudSelection()
      self?.machines.pruneDeadCloudRecords()
      if let self, self.directMachineAdoption.hasPendingMachines {
        Task { await self.directMachineAdoption.adoptPendingMachines(cloud: self.cloud) }
      }
    }
    directMachineAdoption.onSettled = { [weak self] oldId, cloudId in
      guard let self else { return }
      self.projectList.removeAllRecords(serverId: oldId)
      if let cloudId, self.composerDefaults.lastNewWorkspaceServerId == oldId {
        self.composerDefaults.rememberNewWorkspaceServer(serverId: cloudId)
      }
    }
  }

  private func wireHarnessAndConfigurationSync() {
    machines.onHarnessLifecycleChanged = { [weak self] in self?.noteHarnessLifecycle(onServer: $0) }
    machines.onHarnessAuthChanged = { [weak self] in self?.harnessCatalogDidChange(onServer: $0) }
    machines.onSyncChanged = { [weak self] in
      self?.configSync.applyRemoteChange(namespace: $1.namespace, entries: $1.entries, fromMachine: $0)
    }
    configSync.onNamespaceChanged = { [weak self] in self?.applySyncedNamespace($0) }
    configSync.startPeriodicSweep()
    configSync.onHarnessCatalogChanged = { [weak self] in
      self?.harnessCatalogDidChange(onServer: $0)
    }
    machines.onMachineConnected = { [weak self] in self?.noteMachineConnected($0) }
    machines.onHarnessNotice = { [weak self] in self?.showHarnessNotice($0) }
    machines.onSessionStateChanged = { [weak self] in self?.onSessionStateChanged?($0, $1) }
  }

  private func wireResourceChangeCallbacks() {
    machines.onPluginStateChanged = { [weak self] in self?.pluginStateDidChange(onServer: $0) }
    machines.onMcpStateChanged = { [weak self] in self?.mcpStateDidChange(onServer: $0) }
    machines.onBotsChanged = { [weak self] serverId in
      guard let bots = self?.bots else { return }
      Task { await bots.refresh(serverId: serverId) }
    }
    machines.onPluginUpdated = { [weak self] in self?.pluginDidUpdate(onServer: $0, pluginId: $1) }
  }

  private func backfillComposerDefaultsFromPersistedState() {
    var latestByServer: [String: ChatSession] = [:]
    for session in projectList.sessions where session.origin == .codevisor {
      let previous = latestByServer[session.serverId]
      if previous == nil || session.createdAt > previous!.createdAt {
        latestByServer[session.serverId] = session
      }
    }
    for session in latestByServer.values {
      composerDefaults.backfillNewWorkspaceDefaults(
        serverId: session.serverId,
        projectId: session.projectId,
        createsWorktree: session.worktreeName?.isEmpty == false
      )
    }
  }

  public func importSessions(_ imported: [ImportedSession], into project: Project) {
    projectList.importSessions(imported, into: project)
    settings.setImportExternalSessions(true)
    projectList.showsImportedSessions = true
  }

  public func warmHarnessCapabilities(for serverId: String) async {
    guard configCache.needsCapabilityWarm(forServer: serverId) else { return }
    let (client, cacheRevision) = (
      machines.client(for: serverId), configCache.capabilityRevision(forServer: serverId)
    )
    do {
      let response = try await client.capabilities(
        cwd: FileManager.default.temporaryDirectory.path
      )
      let capabilities = response.harnesses.filter { capability in
        capability.harness.enabled && capability.harness.isReady
      }
      configCache.storeIfEmpty(capabilities, forServer: serverId, ifRevision: cacheRevision)
    } catch {
      Log.onboarding.error(
        "Capability cache warm failed: \(String(describing: error), privacy: .public)"
      )
    }
  }

  public func deleteAllData() {
    AnalyticsClient.shared.setEnabled(false)
    DiagnosticsClient.shared.setEnabled(false)
    projectList.removeAll()
    configCache.clear()
    composerDefaults.clear()
    composerDrafts.clear()
    paneGroups.removeAll()
    workspaces.removeAll()
    machines.resetSelection()
    directMachineAdoption.reset()
    cloud.signOut()
    ClientPreferences.shared.removeAll()
    do {
      try clientDataResetter?.resetClientData()
    } catch {
      Log.persistence.error(
        "Failed to clear client SQLite data: \(String(describing: error), privacy: .public)"
      )
    }
    setLocalNetworkAccess(.unasked)
    settings.reset()
    appUpdate.setAllowsAlphaUpdates(settings.alphaUpdatesEnabled)
    projectList.showsImportedSessions = settings.importExternalSessions
  }

  public func setShareAnalytics(_ enabled: Bool) {
    settings.setShareAnalytics(enabled)
    AnalyticsClient.shared.setEnabled(enabled)
  }

  public func setShareCrashReports(_ enabled: Bool) {
    settings.setShareCrashReports(enabled)
    DiagnosticsClient.shared.setEnabled(enabled)
  }

  public static func preview(
    seedProjects: [Project] = AppEnvironment.sampleProjects,
    seedSessions: [ChatSession] = AppEnvironment.sampleSessions,
    seedCloudMachines: [CloudMachine] = [],
    seedCapabilities: [ServerHarnessCapability] = []
  ) -> AppEnvironment {
    let settings = AppSettingsModel(store: InMemoryStore())
    let machineStore = InMemoryStore()
    settings.completeOnboarding(importExternalSessions: false)
    settings.setShareCrashReports(false)
    let environment = AppEnvironment(
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: settings,
      machineStore: machineStore,
      harnessService: PreviewHarnessService(),
      machineClientFactory: { _ in PreviewServerClient(harnessCapabilities: seedCapabilities) }
    )
    if !seedCloudMachines.isEmpty {
      environment.machines.cloudProvider = PreviewCloudMachines(cloudMachines: seedCloudMachines)
    }
    for project in seedProjects {
      environment.navigationStore.enqueue(.upsertProject(project), machineId: project.serverId)
    }
    for session in seedSessions {
      environment.navigationStore.enqueue(.upsertSession(session, workspaceId: nil), machineId: session.serverId)
    }
    return environment
  }

  public func markNavigationCurrentForPreview(machineIds: [String]) {
    for machineId in machineIds {
      machines.connection(for: machineId).navigationSyncState = .current
    }
  }

  public static let sampleProjects: [Project] = [
    Project.fromFolder(
      URL(fileURLWithPath: "/Users/me/src/Codevisor"), createdAt: Date(timeIntervalSince1970: 2_000)),
    Project.fromFolder(
      URL(fileURLWithPath: "/Users/me/src/website"), createdAt: Date(timeIntervalSince1970: 1_000)),
    Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/scratch"), createdAt: Date(timeIntervalSince1970: 750)),
  ]

  public static let sampleSessions: [ChatSession] = [
    ChatSession(
      projectId: sampleProjects[0].id,
      harnessId: "claude-code",
      agentSessionId: "preview-1",
      title: "Fix onboarding crash",
      createdAt: Date(timeIntervalSinceNow: -9_000),
      updatedAt: Date(timeIntervalSinceNow: -1_800)
    ),
    ChatSession(
      projectId: sampleProjects[0].id,
      harnessId: "codex",
      agentSessionId: "preview-2",
      title: "Add dark mode support",
      createdAt: Date(timeIntervalSinceNow: -172_800),
      updatedAt: Date(timeIntervalSinceNow: -86_400)
    ),
    ChatSession(
      projectId: sampleProjects[1].id,
      harnessId: "claude-code",
      agentSessionId: "preview-3",
      title: "Refresh landing page copy",
      createdAt: Date(timeIntervalSinceNow: -432_000),
      updatedAt: Date(timeIntervalSinceNow: -345_600)
    ),
  ]
}

public struct PreviewHarnessService: HarnessServicing {
  public init() {}

  public func readyHarnesses() async -> [ServerHarness] {
    [
      ServerHarness(
        id: "claude-code", name: "Claude Code", symbolName: "sparkle", source: "registry",
        launchKind: "executable", enabled: true,
        readiness: ServerHarnessReadiness(state: "ready")
      ),
      ServerHarness(
        id: "codex", name: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry", launchKind: "executable", enabled: true,
        readiness: ServerHarnessReadiness(state: "ready")
      ),
    ]
  }

  public func allHarnesses() async -> [ServerHarness] {
    await readyHarnesses() + [
      ServerHarness(
        id: "gemini", name: "Gemini CLI", symbolName: "diamond", source: "registry",
        launchKind: "npx", enabled: true,
        readiness: ServerHarnessReadiness(state: "unavailable", detail: "Not installed")
      ),
      ServerHarness(
        id: "opencode", name: "OpenCode", symbolName: "curlybraces", source: "registry",
        launchKind: "executable", enabled: true,
        readiness: ServerHarnessReadiness(state: "unavailable", detail: "Not installed"),
        installHint: "npm install -g opencode-ai"
      ),
    ]
  }

  public func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
    [
      SessionInfo(sessionId: "ext-1", cwd: "/Users/me/src/website", title: "Fix the landing page"),
      SessionInfo(sessionId: "ext-2", cwd: "/Users/me/src/Codevisor", title: "Add tests"),
    ]
  }
}
