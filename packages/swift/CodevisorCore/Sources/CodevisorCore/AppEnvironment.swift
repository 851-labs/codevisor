import Foundation
import Observation
import ACPKit
import CodevisorTheming

/// The composition root: wires repositories and services together and vends the
/// top-level view models. Inject a configured instance into the SwiftUI
/// environment; use `preview` for previews and tests.
@MainActor
@Observable
public final class AppEnvironment {
  public let projectList: ProjectListModel
  /// App-wide attention policy: focus auto-read + edge-triggered
  /// notifications. Platforms feed it focus (`updateFocus`) and, on macOS,
  /// assign `notificationDelivery` after launch.
  public let attentionCoordinator: SessionAttentionCoordinator
  public let configCache: ConfigOptionCache
  public let composerDefaults: ComposerDefaultsStore
  public let composerDrafts: ComposerDraftStore
  public let settings: AppSettingsModel
  public let theme: ThemeManager
  public let machines: MachineController
  public let cloud: CloudAccountController
  /// Moves retired directly paired machines onto the signed-in account.
  public let directMachineAdoption: DirectMachineCloudAdoption
  public let pluginAccess: PluginAccessController
  public let localServer: (any LocalServerControlling)?
  public let appUpdate: AppUpdateModel
  /// The fleet-wide update fold (app + servers + harnesses + plugins
  /// across every machine) behind the update sheet and ambient indicator.
  public let updateCenter: UpdateCenter
  /// The config plane's client half: local replica + cross-machine gossip.
  public let configSync: ConfigSync
  /// Set at launch when an already-onboarded install is missing the system
  /// permissions Computer Use needs (typically right after an update).
  /// While true, the root view presents the blocking permissions gate
  /// instead of the main split. Cleared when the gate completes.
  public var requiresPermissionsReview = false

  /// The last project suggestions each machine returned, so reopening the
  /// add-project surface shows them at once while a fresh request runs.
  @ObservationIgnored var projectRecommendationCache: [String: [ProjectRecommendation]] = [:]
  @ObservationIgnored public var onSessionStateChanged: ((ChatSession, Int?) -> Void)?
  /// Persists each session's pane-group state (terminal tabs, selection,
  /// panel visibility/height) so panes reattach to their shells after
  /// app restarts.
  public let paneGroups: any PaneGroupRepository
  public let workspaces: any WorkspaceRepository
  /// The one owner of navigation state: cached server state per machine,
  /// the outbox of pending changes, and this device's layouts.
  public let navigationStore: NavigationStore
  /// The latest page of recently opened chats, on disk. Nil in previews and
  /// tests, which must not write to the user's caches.
  public let transcriptCache: TranscriptPageCache?
  /// Shared server-metadata reconciliation and navigation invalidation for
  /// both native platforms. Pane layout itself remains in `workspaces`.
  public let workspaceSync: WorkspaceSyncModel
  /// Overrides server-backed harness discovery (previews/tests only).
  let harnessServiceOverride: (any HarnessServicing)?
  /// Monotonic, per-machine invalidation tokens for consumers that keep a
  /// harness catalog alive (most notably an already-mounted new-chat page).
  var harnessCatalogRevisions: [String: UInt64] = [:]
  /// Monotonic, per-machine invalidation tokens bumped by
  /// `plugin.state.updated` events; the Plugins settings pane and New Tab
  /// cards observe these and refetch the list. Accessors live in
  /// AppEnvironment+Plugins.swift.
  var pluginStateRevisions: [String: UInt64] = [:]
  /// Monotonic, per-machine invalidation tokens bumped by `mcp.updated`
  /// events; the MCP settings panes observe these and refetch the server
  /// list. Accessors live in AppEnvironment+Mcp.swift.
  var mcpStateRevisions: [String: UInt64] = [:]
  /// Monotonic, per-plugin reload tokens (keyed "serverId|pluginId") bumped
  /// by `plugin.updated` events; open plugin panes observe their plugin's
  /// token and re-run the full token→load flow when it moves. Accessors
  /// live in AppEnvironment+Plugins.swift.
  var pluginUpdateRevisions: [String: UInt64] = [:]
  private let clientDataResetter: (any ClientDataResetting)?

  public init(
    navigationPersistence: any PersistenceStore = InMemoryStore(),
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
    customThemesDirectory: URL? = nil,
    harnessService: (any HarnessServicing)? = nil,
    machineClientFactory: MachineController.ClientFactory? = nil
  ) {
    self.harnessServiceOverride = harnessService
    self.paneGroups = paneGroups
    self.transcriptCache = transcriptCache
    // The old storage kept editable copies of server state; keep only the
    // tab arrangements before the store opens (see NavigationStoreMigration).
    NavigationStoreMigration.runIfNeeded(
      store: navigationPersistence, machineIds: [CodevisorMachine.local.id])
    let navigationStore = NavigationStore(store: navigationPersistence)
    self.navigationStore = navigationStore
    let workspaces = ProjectedWorkspaceRepository(store: navigationStore)
    self.workspaces = workspaces
    self.theme = ThemeManager(
      settings: settings,
      catalog: ThemeCatalog(
        customThemesDirectory: customThemesDirectory
          ?? FileManager.default.temporaryDirectory
          .appendingPathComponent("codevisor-themes-\(UUID().uuidString)")
      )
    )
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
    self.workspaceSync = WorkspaceSyncModel(
      repository: workspaces,
      projectList: projectList
    )
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
    updateCenter = UpdateCenter(machines: machines, appUpdate: self.appUpdate)
    configSync = ConfigSync(machines: machines)
    // Updates cover the harnesses in the shared list, once it has synced.
    updateCenter.listedHarnessIds = { [configSync] in
      guard configSync.hasSnapshot(namespace: "harnesses") else { return nil }
      return Set(HarnessFleet.settings(configSync).map(\.id))
    }
    // Previews/tests without a device credential store stay hermetic: an
    // in-memory store, and no networking until someone calls bootstrap().
    self.cloud = CloudAccountController(
      credentialStore: cloudCredentialStore ?? InMemoryCloudCredentialStore()
    )
    self.pluginAccess = PluginAccessController(cloud: cloud, store: machineStore)
    self.directMachineAdoption = DirectMachineCloudAdoption(store: machineStore)
    #if os(iOS)
      updateCenter.reviewPluginUpdate = { [pluginAccess] _, plan in
        try await pluginAccess.requireEligible(pluginId: plan.pluginId, ageRating: plan.candidate.ageRating)
      }
    #endif
    // Cloud machines are first-class members of the machine list: the
    // controller reads presence (and relay transports) from the account.
    machines.cloudProvider = cloud
    // Platforms with an embedded server (macOS) register this machine on
    // the signed-in account automatically, so it appears on the user's
    // other devices without a separate `codevisor auth login`.
    if localServer != nil {
      cloud.localServerClient = machines.client(for: CodevisorMachine.local.id)
    }
    cloud.onLocalMachineRegistrationResolved = { [weak self] deviceId in
      self?.machines.adoptLocalCloudIdentity(deviceId: deviceId)
    }
    cloud.onSignedOut = { [weak self] in
      self?.machines.handleCloudAccountSignedOut()
    }
    cloud.onMachinesRefreshed = { [weak self] in
      if let access = self?.pluginAccess { Task { try? await access.syncConsent() } }
      self?.machines.reconcileCloudSelection()
      self?.machines.pruneDeadCloudRecords()
      // A verified roster is when retired directly paired machines can be
      // moved onto the account (or recognized as already on it).
      if let self, self.directMachineAdoption.hasPendingMachines {
        Task { await self.directMachineAdoption.adoptPendingMachines(cloud: self.cloud) }
      }
    }
    // A settled machine's chats and projects re-sync under its cloud id (if
    // it moved); the records cached under its old direct id would render as
    // duplicates or strays.
    directMachineAdoption.onSettled = { [weak self] oldId, cloudId in
      guard let self else { return }
      self.projectList.removeAllRecords(serverId: oldId)
      if let cloudId, self.composerDefaults.lastNewWorkspaceServerId == oldId {
        self.composerDefaults.rememberNewWorkspaceServer(serverId: cloudId)
      }
    }
    projectList.showsImportedSessions = settings.importExternalSessions
    machines.serverUpdateChannel = settings.alphaUpdatesEnabled ? .alpha : .stable
    // The hub turns the tunnel on for Alpha devices only.
    reportReleaseChannel(alpha: settings.alphaUpdatesEnabled)
    machines.onHarnessLifecycleChanged = { [weak self] in self?.noteHarnessLifecycle(onServer: $0) }
    machines.onHarnessAuthChanged = { [weak self] in self?.harnessCatalogDidChange(onServer: $0) }
    machines.onSyncChanged = { [weak self] in
      self?.configSync.applyRemoteChange(namespace: $1.namespace, entries: $1.entries)
    }
    configSync.onNamespaceChanged = { [weak self] in self?.applySyncedNamespace($0) }
    // The reconvergence loop: one-shot sync triggers can fail while a
    // machine is mid-boot; the sweep guarantees the fleet settles anyway.
    configSync.startPeriodicSweep()
    configSync.onHarnessCatalogChanged = { [weak self] in
      self?.harnessCatalogDidChange(onServer: $0)
    }
    machines.onMachineConnected = { [weak self] in self?.noteMachineConnected($0) }
    machines.onSessionStateChanged = { [weak self] in self?.onSessionStateChanged?($0, $1) }
    applyBootSyncState()
    machines.onPluginStateChanged = { [weak self] in self?.pluginStateDidChange(onServer: $0) }
    machines.onMcpStateChanged = { [weak self] in self?.mcpStateDidChange(onServer: $0) }
    machines.onPluginUpdated = { [weak self] in self?.pluginDidUpdate(onServer: $0, pluginId: $1) }
    backfillComposerDefaultsFromPersistedState()
    // One-time compatibility bridge from the old app-wide machine
    // selection. From this point on the value lives only in the composer
    // defaults store and never drives server lifecycle or routing.
    if self.composerDefaults.lastNewWorkspaceServerId == nil,
      machines.machine(for: machines.selectedMachineId) != nil
    {
      self.composerDefaults.rememberNewWorkspaceServer(serverId: machines.selectedMachineId)
    }
  }

  /// Seeds the standalone page's project and legacy worktree choice once,
  /// for clients that predate that memory. Chat configuration is never
  /// copied into New Chat defaults: only explicit draft picks write them.
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

  /// Refetches sessions from all harnesses and merges them in.
  public func importSessions(from serverId: String) async {
    let imported = await sessionImporter(for: serverId).fetchAll()
    projectList.importSessions(imported, serverId: serverId)
    projectList.showsImportedSessions = settings.importExternalSessions
  }

  /// Imports the given sessions into a project the user just added. The
  /// import was explicitly requested, so imported sessions are made visible.
  public func importSessions(_ imported: [ImportedSession], into project: Project) {
    projectList.importSessions(imported, into: project)
    settings.setImportExternalSessions(true)
    projectList.showsImportedSessions = true
  }

  /// Best-effort first-run warm for the new-chat composer. Onboarding has
  /// already discovered the harness catalog by this point, but model and
  /// mode metadata come from the more expensive capabilities request. Run
  /// that inspection while the user chooses projects, without delaying the
  /// onboarding flow. The composer still refreshes against its real cwd.
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
      // This is speculative only. The composer owns the visible retry
      // and error state if its normal project-specific load also fails.
      Log.onboarding.error(
        "Capability cache warm failed: \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// Deletes all Codevisor data (projects, sessions, cached config, settings)
  /// and re-triggers onboarding. Does not touch the harnesses' own sessions.
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
    // The Cloud session is local data too: staying signed in would keep
    // every cloud-registered machine listed, and onboarding would never
    // return.
    cloud.signOut()
    ClientPreferences.shared.removeAll()
    do {
      try clientDataResetter?.resetClientData()
    } catch {
      Log.persistence.error(
        "Failed to clear client SQLite data: \(String(describing: error), privacy: .public)"
      )
    }
    settings.reset()
    appUpdate.setAllowsAlphaUpdates(settings.alphaUpdatesEnabled)
    projectList.showsImportedSessions = settings.importExternalSessions
  }

  /// Persists analytics consent and immediately applies it to the delivery
  /// client. This is the only path the onboarding and Settings UI use.
  public func setShareAnalytics(_ enabled: Bool) {
    settings.setShareAnalytics(enabled)
    AnalyticsClient.shared.setEnabled(enabled)
  }

  /// Persists native diagnostics consent and applies it immediately. Sentry
  /// remains completely uninitialized until this preference is enabled.
  public func setShareCrashReports(_ enabled: Bool) {
    settings.setShareCrashReports(enabled)
    DiagnosticsClient.shared.setEnabled(enabled)
  }

  /// Applies the user's onboarding choice and imports if requested.
  public func finishOnboarding(
    importExternalSessions: Bool,
    serverId: String = CodevisorMachine.local.id
  ) async {
    settings.setImportExternalSessions(importExternalSessions)
    projectList.showsImportedSessions = importExternalSessions
    if importExternalSessions {
      await importSessions(from: serverId)
    }
    // This flag replaces onboarding with the main UI. Publish it only
    // after every value that first render consumes is ready.
    settings.completeOnboarding(importExternalSessions: importExternalSessions)
  }

  /// Completes onboarding, importing if requested, and adds the chosen project
  /// folder as a project. Returns the new project so the caller can open a
  /// new chat in it.
  @discardableResult
  public func finishOnboarding(
    importExternalSessions: Bool,
    projectFolder: URL?,
    serverId: String = CodevisorMachine.local.id
  ) async -> Project? {
    let project = projectFolder.map { projectList.addProject(folderURL: $0, serverId: serverId) }
    await finishOnboarding(importExternalSessions: importExternalSessions, serverId: serverId)
    return project
  }

  /// Completes onboarding for the chosen project folders: adds each as a
  /// project and returns the first so the caller can open a new chat in it.
  /// Existing agent chats are deliberately NOT pulled in here — a first
  /// project pre-filled with old CLI sessions the user never asked for
  /// reads as clutter; importing stays an explicit action.
  @discardableResult
  public func finishOnboarding(
    projectFolders: [URL],
    serverId: String = CodevisorMachine.local.id
  ) async -> Project? {
    var first: Project?
    for folder in projectFolders {
      let project = projectList.addProject(folderURL: folder, serverId: serverId)
      if first == nil { first = project }
    }
    await finishOnboarding(importExternalSessions: false, serverId: serverId)
    return first
  }

  /// Single-folder convenience over `finishOnboarding(projectFolders:)`.
  @discardableResult
  public func finishOnboarding(
    projectFolder: URL,
    serverId: String = CodevisorMachine.local.id
  ) async -> Project {
    // The array overload always returns a project for a non-empty list.
    await finishOnboarding(projectFolders: [projectFolder], serverId: serverId)!
  }

  /// An in-memory environment seeded with sample data for previews and tests.
  public static func preview(
    seedProjects: [Project] = AppEnvironment.sampleProjects,
    seedSessions: [ChatSession] = AppEnvironment.sampleSessions,
    seedCloudMachines: [CloudMachine] = [],
    seedCapabilities: [ServerHarnessCapability] = [],
    hasOnboarded: Bool = true
  ) -> AppEnvironment {
    let settings = AppSettingsModel(store: InMemoryStore())
    let machineStore = InMemoryStore()
    if hasOnboarded {
      settings.completeOnboarding(importExternalSessions: false)
      settings.setShareCrashReports(false)
    }
    let environment = AppEnvironment(
      configCache: ConfigOptionCache(store: InMemoryStore()),
      settings: settings,
      machineStore: machineStore,
      harnessService: PreviewHarnessService(),
      // Hermetic: the default factory builds a real HTTP client against
      // the Debug dev port, so previews/tests would sync their sample
      // projects into a live dev server's database.
      machineClientFactory: { _ in PreviewServerClient(harnessCapabilities: seedCapabilities) }
    )
    if !seedCloudMachines.isEmpty {
      environment.machines.cloudProvider = PreviewCloudMachines(cloudMachines: seedCloudMachines)
    }
    // Previews have no server; queued records show exactly as a real
    // machine's would while they wait.
    for project in seedProjects {
      environment.navigationStore.enqueue(.upsertProject(project), machineId: project.serverId)
    }
    for session in seedSessions {
      environment.navigationStore.enqueue(.upsertSession(session, workspaceId: nil), machineId: session.serverId)
    }
    return environment
  }

  public static let sampleProjects: [Project] = [
    Project.fromFolder(
      URL(fileURLWithPath: "/Users/me/src/Codevisor"), createdAt: Date(timeIntervalSince1970: 2_000)),
    Project.fromFolder(
      URL(fileURLWithPath: "/Users/me/src/website"), createdAt: Date(timeIntervalSince1970: 1_000)),
    // No sessions reference this one, so previews exercise the
    // "No sessions yet" empty state.
    Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/scratch"), createdAt: Date(timeIntervalSince1970: 750)),
  ]

  /// Mock sessions for the sample projects, so sidebar previews show
  /// populated project folders instead of "No sessions yet".
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

/// A no-op harness service used in previews.
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
