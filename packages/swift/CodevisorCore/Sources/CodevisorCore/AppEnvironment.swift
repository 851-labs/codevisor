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
    public let localServer: (any LocalServerControlling)?
    public let appUpdate: AppUpdateModel
    /// The fleet-wide update fold (app + servers + harnesses + plugins
    /// across every machine) behind the update sheet and ambient indicator.
    public let updateCenter: UpdateCenter
    /// The config plane's client half: local replica + cross-machine gossip.
    public let configSync: ConfigSync
    public let fleetRoster: FleetRoster
    /// Set at launch when an already-onboarded install is missing the system
    /// permissions Computer Use needs (typically right after an update).
    /// While true, the root view presents the blocking permissions gate
    /// instead of the main split. Cleared when the gate completes.
    public var requiresPermissionsReview = false

    /// App-installed: fired when a machine's route flips (direct ↔ relay)
    /// so the platform's chat cache can re-home live sessions onto a client
    /// resolved over the new route.
    @ObservationIgnored public var onMachineRouteChanged: ((String) -> Void)?
    /// Persists each session's pane-group state (terminal tabs, selection,
    /// panel visibility/height) so panes reattach to their shells after
    /// app restarts.
    public let paneGroups: any PaneGroupRepository
    public let workspaces: any WorkspaceRepository
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
    /// Monotonic, per-plugin reload tokens (keyed "serverId|pluginId") bumped
    /// by `plugin.updated` events; open plugin panes observe their plugin's
    /// token and re-run the full token→load flow when it moves. Accessors
    /// live in AppEnvironment+Plugins.swift.
    var pluginUpdateRevisions: [String: UInt64] = [:]
    var harnessLifecycleByServer: [String: [ServerHarness]] = [:]
    private let clientDataResetter: (any ClientDataResetting)?

    public init(
        projectRepository: any ProjectRepository,
        sessionRepository: any SessionRepository,
        configCache: ConfigOptionCache,
        composerDefaults: ComposerDefaultsStore? = nil,
        composerDrafts: ComposerDraftStore? = nil,
        settings: AppSettingsModel,
        machineStore: any PersistenceStore = InMemoryStore(),
        machineCredentialStore: (any MachineCredentialStore)? = nil,
        cloudCredentialStore: (any CloudCredentialStore)? = nil,
        legacyCacheMigrationStore: (any PersistenceStore)? = nil,
        paneGroups: any PaneGroupRepository = DefaultPaneGroupRepository(store: InMemoryStore()),
        workspaces: any WorkspaceRepository = DefaultWorkspaceRepository(store: InMemoryStore()),
        localServer: (any LocalServerControlling)? = nil,
        appUpdate: AppUpdateModel? = nil,
        customThemesDirectory: URL? = nil,
        harnessService: (any HarnessServicing)? = nil,
        machineClientFactory: MachineController.ClientFactory? = nil
    ) {
        self.harnessServiceOverride = harnessService
        self.paneGroups = paneGroups
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
        self.projectList = ProjectListModel(
            projectRepository: projectRepository,
            sessionRepository: sessionRepository,
            legacyMigrationStore: legacyCacheMigrationStore
        )
        self.attentionCoordinator = SessionAttentionCoordinator(projectList: projectList)
        self.workspaceSync = WorkspaceSyncModel(
            repository: workspaces,
            projectList: projectList
        )
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
            credentialStore: machineCredentialStore,
            localServer: localServer,
            clientFactory: machineClientFactory
        )
        updateCenter = UpdateCenter(machines: machines, appUpdate: self.appUpdate)
        configSync = ConfigSync(machines: machines)
        fleetRoster = FleetRoster(machines: machines, configSync: configSync)
        // Previews/tests without a device credential store stay hermetic: an
        // in-memory store, and no networking until someone calls bootstrap().
        self.cloud = CloudAccountController(
            credentialStore: cloudCredentialStore ?? InMemoryCloudCredentialStore()
        )
        // Cloud machines are first-class members of the machine list: the
        // controller reads presence (and relay transports) from the account.
        machines.cloudProvider = cloud
        // Platforms with an embedded server (macOS) register this machine on
        // the signed-in account automatically, so it appears on the user's
        // other devices without a separate `codevisor auth login`.
        if localServer != nil {
            cloud.localServerClient = machines.client(for: CodevisorMachine.local.id)
        }
        cloud.onSignedOut = { [weak self] in
            self?.machines.handleCloudAccountSignedOut()
        }
        cloud.onMachinesRefreshed = { [weak self] in
            self?.machines.reconcileCloudSelection()
            self?.machines.pruneDeadCloudRecords()
        }
        projectList.showsImportedSessions = settings.importExternalSessions
        machines.serverUpdateChannel = settings.alphaUpdatesEnabled ? .alpha : .stable
        machines.onHarnessLifecycleChanged = { [weak self] in self?.noteHarnessLifecycle(onServer: $0) }
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
        machines.onMachineRouteChanged = { [weak self] in self?.onMachineRouteChanged?($0) }
        machines.onMachineAdded = { [weak self] in self?.fleetRoster.publishMachine($0) }
        machines.onMachineRemoved = { [weak self] in
            self?.fleetRoster.publishRemoval(localMachineId: $0)
        }
        applyBootSyncState()
        machines.onPluginStateChanged = { [weak self] in self?.pluginStateDidChange(onServer: $0) }
        machines.onPluginUpdated = { [weak self] in self?.pluginDidUpdate(onServer: $0, pluginId: $1) }
        // One-time split of pre-"1 workspace == 1 directory" workspaces whose
        // chats live in different worktrees. Runs before any window renders
        // (no workspace models are cached yet); sessions load synchronously
        // in ProjectListModel.init, so the grouping inputs are complete.
        // In-memory repositories (previews, iOS) no-op via the marker.
        WorkspaceWorktreeSplitMigration.runIfNeeded(
            workspaces: workspaces,
            sessions: projectList.sessions.map {
                .init(sessionId: $0.id, worktreeName: $0.worktreeName, cwd: $0.cwd)
            },
            projectNames: Dictionary(
                projectList.projects.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        backfillComposerDefaultsFromPersistedState()
    }

    /// V4 introduced an explicit standalone-page project and restored
    /// workspace-scoped chat inheritance. Seed missing profiles from durable
    /// sessions once; picker/focus writes remain authoritative thereafter.
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
                createsWorktree: session.worktreeName?.isEmpty == false,
                harnessId: session.harnessId,
                configValues: session.configSelections ?? [:]
            )
        }

        for workspace in workspaces.loadAll() {
            let selectedChatId = workspace.selectedCenterTab
                .flatMap { tab in tab.root.group(id: tab.activeLeafId) }
                .flatMap(\.selectedPane)
                .flatMap { $0.kind == .chat ? $0.chatSessionId : nil }
            let candidateIds =
                [selectedChatId].compactMap { $0 }
                + workspace.chatSessionIds.filter { $0 != selectedChatId }
            let candidates = candidateIds.compactMap { id in
                projectList.sessions.first {
                    $0.serverId == workspace.serverId && $0.id == id
                }
            }
            let source =
                candidates.first
                ?? projectList.sessions
                .filter {
                    $0.serverId == workspace.serverId
                        && workspaces.workspaceId(forSession: $0.id) == workspace.id
                }
                .max {
                    ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt)
                }
            guard let source else { continue }
            composerDefaults.backfillWorkspaceDefaults(
                workspaceId: workspace.id,
                serverId: workspace.serverId,
                harnessId: source.harnessId,
                configValues: source.configSelections ?? [:]
            )
        }
    }

    /// Refetches sessions from all harnesses and merges them in.
    public func importSessions() async {
        // Snapshot which machine the discovery runs against BEFORE awaiting:
        // if the user switches machines mid-fetch, the results must still be
        // filed under the machine they came from, not the new selection.
        let serverId = machines.selectedMachineId
        let imported = await sessionImporter.fetchAll()
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

    /// Archives a chat without changing its workspace. This is the tab-close
    /// behavior: an empty workspace remains available for its New Tab page.
    public func archiveSession(_ session: ChatSession) {
        projectList.archiveSession(session)
    }

    /// Archives a chat and, when it was the workspace's final active chat,
    /// archives the workspace with it. This is the sidebar archive policy.
    /// Returns true when the workspace was archived so callers can leave its
    /// now-hidden route.
    @discardableResult
    public func archiveSessionAndWorkspaceIfEmpty(_ session: ChatSession) -> Bool {
        archiveSession(session)

        guard let workspaceId = workspaces.workspaceId(forSession: session.id),
            let workspace = workspaces.workspace(id: workspaceId),
            !workspace.isArchived
        else { return false }

        let hasActiveChat = projectList.sessions.contains { candidate in
            candidate.serverId == workspace.serverId
                && !candidate.isArchived
                && workspaces.workspaceId(forSession: candidate.id) == workspace.id
        }
        guard !hasActiveChat else { return false }

        setWorkspaceArchived(workspace, true)
        return true
    }

    /// Archives a workspace and every active chat that belongs to it while
    /// retaining its pane layout for a later restore.
    public func archiveWorkspace(_ workspace: Workspace) {
        setWorkspaceArchived(workspace, true)

        for session in projectList.sessions
        where
            session.serverId == workspace.serverId
            && !session.isArchived
            && workspaces.workspaceId(forSession: session.id) == workspace.id
        {
            projectList.archiveSession(session)
        }
    }

    /// Restores a workspace. Its chats are revived by the server's cascade
    /// (it archived them, so it owns un-archiving them); locally we clear the
    /// flag so the row reappears immediately rather than after a refresh.
    public func unarchiveWorkspace(_ workspace: Workspace) {
        setWorkspaceArchived(workspace, false)
    }

    /// Writes the archived flag locally AND mirrors it to the server.
    ///
    /// The local write is what the sidebar reads, so it stays first and
    /// unconditional — the archive must work offline. The upload is
    /// best-effort and fire-and-forget: without it the flag never left this
    /// machine, so other devices kept showing the workspace and the server
    /// never cascaded the archive to its chats.
    private func setWorkspaceArchived(_ workspace: Workspace, _ isArchived: Bool) {
        var updated = workspace
        updated.isArchived = isArchived
        workspaces.save(updated)
        workspaceSync.noteLocalMutation()

        guard machines.machine(for: workspace.serverId) != nil else { return }
        let client = machines.client(for: workspace.serverId)
        Task {
            do {
                try await client.setWorkspaceArchived(id: workspace.id, isArchived: isArchived)
            } catch {
                Log.sync.error(
                    "Failed to sync workspace archive state: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Best-effort first-run warm for the new-chat composer. Onboarding has
    /// already discovered the harness catalog by this point, but model and
    /// mode metadata come from the more expensive capabilities request. Run
    /// that inspection while the user chooses projects, without delaying the
    /// onboarding flow. The composer still refreshes against its real cwd.
    public func warmHarnessCapabilities() async {
        let serverId = machines.selectedMachineId
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
        machines.removeAllRemoteMachines()
        // The Cloud session is local data too: staying signed in would
        // re-synthesize every cloud-registered machine the instant the
        // configured ones were removed, and onboarding would never return.
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
    public func finishOnboarding(importExternalSessions: Bool) async {
        settings.setImportExternalSessions(importExternalSessions)
        projectList.showsImportedSessions = importExternalSessions
        if importExternalSessions {
            await importSessions()
        }
        // This flag replaces onboarding with the main UI. Publish it only
        // after every value that first render consumes is ready.
        settings.completeOnboarding(importExternalSessions: importExternalSessions)
    }

    /// Completes onboarding, importing if requested, and adds the chosen project
    /// folder as a project. Returns the new project so the caller can open a
    /// new chat in it.
    @discardableResult
    public func finishOnboarding(importExternalSessions: Bool, projectFolder: URL?) async -> Project? {
        let project = projectFolder.map { projectList.addProject(folderURL: $0) }
        await finishOnboarding(importExternalSessions: importExternalSessions)
        return project
    }

    /// Completes onboarding for the chosen project folders: adds each as a
    /// project and returns the first so the caller can open a new chat in it.
    /// Existing agent chats are deliberately NOT pulled in here — a first
    /// project pre-filled with old CLI sessions the user never asked for
    /// reads as clutter; importing stays an explicit action.
    @discardableResult
    public func finishOnboarding(projectFolders: [URL]) async -> Project? {
        var first: Project?
        for folder in projectFolders {
            let project = projectList.addProject(folderURL: folder)
            if first == nil { first = project }
        }
        await finishOnboarding(importExternalSessions: false)
        return first
    }

    /// Single-folder convenience over `finishOnboarding(projectFolders:)`.
    @discardableResult
    public func finishOnboarding(projectFolder: URL) async -> Project {
        // The array overload always returns a project for a non-empty list.
        await finishOnboarding(projectFolders: [projectFolder])!
    }

    /// An in-memory environment seeded with sample data for previews and tests.
    public static func preview(
        seedProjects: [Project] = AppEnvironment.sampleProjects,
        seedSessions: [ChatSession] = AppEnvironment.sampleSessions,
        hasOnboarded: Bool = true
    ) -> AppEnvironment {
        let store = InMemoryStore()
        let projectRepository = DefaultProjectRepository(store: store)
        let sessionRepository = DefaultSessionRepository(store: InMemoryStore())
        projectRepository.save(seedProjects)
        sessionRepository.save(seedSessions)
        let settings = AppSettingsModel(store: InMemoryStore())
        if hasOnboarded {
            settings.completeOnboarding(importExternalSessions: false)
            settings.setShareCrashReports(false)
        }
        return AppEnvironment(
            projectRepository: projectRepository,
            sessionRepository: sessionRepository,
            configCache: ConfigOptionCache(store: InMemoryStore()),
            settings: settings,
            machineStore: InMemoryStore(),
            harnessService: PreviewHarnessService(),
            // Hermetic: the default factory builds a real HTTP client against
            // the Debug dev port, so previews/tests would sync their sample
            // projects into a live dev server's database.
            machineClientFactory: { _ in PreviewServerClient() }
        )
    }

    public static let sampleProjects: [Project] = [
        Project.fromFolder(
            URL(fileURLWithPath: "/Users/me/src/Codevisor"), createdAt: Date(timeIntervalSince1970: 2_000)),
        Project.fromFolder(
            URL(fileURLWithPath: "/Users/me/src/website"), createdAt: Date(timeIntervalSince1970: 1_000)),
        // No sessions reference this one, so previews exercise the
        // "No sessions yet" empty state.
        Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/scratch"), createdAt: Date(timeIntervalSince1970: 750)),
        archivedSampleProject,
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

    private static var archivedSampleProject: Project {
        var project = Project.fromFolder(
            URL(fileURLWithPath: "/Users/me/src/old"), createdAt: Date(timeIntervalSince1970: 500))
        project.isArchived = true
        return project
    }
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
