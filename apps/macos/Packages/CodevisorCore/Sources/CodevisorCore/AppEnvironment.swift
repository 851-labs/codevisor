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
    public let configCache: ConfigOptionCache
    public let composerDefaults: ComposerDefaultsStore
    public let composerDrafts: ComposerDraftStore
    public let settings: AppSettingsModel
    public let theme: ThemeManager
    public let machines: MachineController
    public let localServer: LocalCodevisorServer?
    public let appUpdate: AppUpdateModel
    /// Persists each session's pane-group state (terminal tabs, selection,
    /// panel visibility/height) so panes reattach to their shells after
    /// app restarts.
    public let paneGroups: any PaneGroupRepository
    public let workspaces: any WorkspaceRepository
    /// Persists each session's scratchpad (inspector notes + open state).
    public let scratchpads: any ScratchpadRepository
    /// Overrides server-backed harness discovery (previews/tests only).
    private let harnessServiceOverride: (any HarnessServicing)?
    /// Monotonic, per-machine invalidation tokens for consumers that keep a
    /// harness catalog alive (most notably an already-mounted new-chat page).
    private var harnessCatalogRevisions: [String: UInt64] = [:]
    private var harnessLifecycleByServer: [String: [ServerHarness]] = [:]

    public var serverClient: any CodevisorServerClienting {
        machines.selectedClient
    }

    /// True while an app self-update or a selected-server update is installing.
    /// Drives the composer lock so no new turn starts during the restart.
    public var isUpdateInProgress: Bool {
        appUpdate.isUpdating || machines.serverUpdatePhase == .updating
    }

    public var harnessService: any HarnessServicing {
        harnessService(for: machines.selectedMachineId)
    }

    public var sessionImporter: SessionImporter {
        SessionImporter(harnessService: harnessService)
    }

    public init(
        projectRepository: any ProjectRepository,
        sessionRepository: any SessionRepository,
        configCache: ConfigOptionCache,
        composerDefaults: ComposerDefaultsStore? = nil,
        composerDrafts: ComposerDraftStore? = nil,
        settings: AppSettingsModel,
        machineStore: any PersistenceStore = InMemoryStore(),
        legacyCacheMigrationStore: (any PersistenceStore)? = nil,
        paneGroups: any PaneGroupRepository = DefaultPaneGroupRepository(store: InMemoryStore()),
        workspaces: any WorkspaceRepository = DefaultWorkspaceRepository(store: InMemoryStore()),
        scratchpads: any ScratchpadRepository = DefaultScratchpadRepository(store: InMemoryStore()),
        localServer: LocalCodevisorServer? = nil,
        appUpdate: AppUpdateModel? = nil,
        customThemesDirectory: URL? = nil,
        harnessService: (any HarnessServicing)? = nil,
        machineClientFactory: MachineController.ClientFactory? = nil
    ) {
        self.harnessServiceOverride = harnessService
        self.paneGroups = paneGroups
        self.workspaces = workspaces
        self.scratchpads = scratchpads
        self.theme = ThemeManager(
            settings: settings,
            catalog: ThemeCatalog(
                customThemesDirectory: customThemesDirectory
                    ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent("codevisor-themes-\(UUID().uuidString)")
            )
        )
        self.appUpdate = appUpdate ?? AppUpdateModel(
            currentVersion: AppUpdateModel.bundleVersion(),
            checker: DisabledUpdateChecker()
        )
        self.projectList = ProjectListModel(
            projectRepository: projectRepository,
            sessionRepository: sessionRepository,
            legacyMigrationStore: legacyCacheMigrationStore
        )
        self.configCache = configCache
        self.composerDefaults = composerDefaults ?? ComposerDefaultsStore(store: InMemoryStore())
        self.composerDrafts = composerDrafts ?? ComposerDraftStore(store: InMemoryStore())
        self.settings = settings
        self.localServer = localServer
        self.machines = MachineController(
            store: machineStore,
            projectList: projectList,
            localServer: localServer,
            clientFactory: machineClientFactory
        )
        projectList.showsImportedSessions = settings.importExternalSessions
        machines.onHarnessLifecycleChanged = { [weak self] serverId in
            self?.harnessCatalogDidChange(onServer: serverId)
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

    /// Project-folder suggestions based on the user's most recent harness
    /// sessions (used by onboarding's project step). Worktree activity is
    /// attributed to its primary checkout — see `ProjectRecommender`.
    public func recommendedProjects(limit: Int = 12) async -> [ProjectRecommendation] {
        ProjectRecommender.recommend(from: await sessionImporter.fetchAll(), limit: limit)
    }

    /// Harness sessions whose working directory is the given folder and that
    /// aren't already tracked by Codevisor.
    public func findImportableSessions(for folderURL: URL) async -> [ImportedSession] {
        let folderPath = folderURL.standardizedFileURL.path
        return await sessionImporter.fetchAll().filter { item in
            let matchesFolder = URL(fileURLWithPath: item.info.cwd).standardizedFileURL.path == folderPath
            let alreadyKnown = projectList.sessions.contains {
                $0.serverId == machines.selectedMachineId
                    && $0.harnessId == item.harnessId
                    && $0.agentSessionId == item.info.sessionId
            }
            return matchesFolder && !alreadyKnown
        }
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
              var workspace = workspaces.workspace(id: workspaceId),
              !workspace.isArchived else { return false }

        let hasActiveChat = projectList.sessions.contains { candidate in
            candidate.serverId == workspace.serverId
                && !candidate.isArchived
                && workspaces.workspaceId(forSession: candidate.id) == workspace.id
        }
        guard !hasActiveChat else { return false }

        workspace.isArchived = true
        workspaces.save(workspace)
        return true
    }

    /// Archives a workspace and every active chat that belongs to it while
    /// retaining its pane layout for a later restore.
    public func archiveWorkspace(_ workspace: Workspace) {
        var archived = workspace
        archived.isArchived = true
        workspaces.save(archived)

        for session in projectList.sessions where
            session.serverId == workspace.serverId
                && !session.isArchived
                && workspaces.workspaceId(forSession: session.id) == workspace.id {
            projectList.archiveSession(session)
        }
    }

    /// Starts the selected machine if it is local, then refreshes cached server
    /// state. Remote machines are never auto-started.
    public func prepareSelectedMachine() async {
        await machines.prepareSelectedMachine()
    }

    /// Best-effort first-run warm for the new-chat composer. Onboarding has
    /// already discovered the harness catalog by this point, but model and
    /// mode metadata come from the more expensive capabilities request. Run
    /// that inspection while the user chooses projects, without delaying the
    /// onboarding flow. The composer still refreshes against its real cwd.
    public func warmHarnessCapabilities() async {
        let serverId = machines.selectedMachineId
        guard configCache.needsCapabilityWarm(forServer: serverId) else { return }
        let client = machines.client(for: serverId)
        do {
            let response = try await client.capabilities(
                cwd: FileManager.default.temporaryDirectory.path
            )
            let capabilities = response.harnesses.filter { capability in
                capability.harness.enabled && capability.harness.isReady
            }
            configCache.storeIfEmpty(capabilities, forServer: serverId)
        } catch {
            // This is speculative only. The composer owns the visible retry
            // and error state if its normal project-specific load also fails.
            Log.onboarding.error(
                "Capability cache warm failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func harnessService(for serverId: String) -> any HarnessServicing {
        harnessServiceOverride ?? ServerHarnessService(client: machines.client(for: serverId))
    }

    /// The current catalog invalidation token for a machine. Views observe
    /// this value and refetch only the machine whose harness state changed.
    public func harnessCatalogRevision(for serverId: String) -> UInt64 {
        harnessCatalogRevisions[serverId, default: 0]
    }

    /// Lifecycle-decorated harnesses (update knowledge, install methods) per
    /// machine, fetched separately from the picker's plain list so the
    /// composer stays snappy. Update banners read this; composer surfaces
    /// refresh it via `refreshHarnessLifecycle`.
    public func harnessLifecycle(for serverId: String) -> [ServerHarness] {
        harnessLifecycleByServer[serverId] ?? []
    }

    public func refreshHarnessLifecycle(for serverId: String) async {
        guard let harnesses = try? await harnessService(for: serverId).allHarnesses() else { return }
        harnessLifecycleByServer[serverId] = harnesses
    }

    /// Publishes that authentication, enablement, or discovery changed the
    /// harnesses available for new chats on a machine.
    public func harnessCatalogDidChange(onServer serverId: String) {
        configCache.invalidateCapabilities(forServer: serverId)
        harnessCatalogRevisions[serverId, default: 0] &+= 1
    }

    /// Forces the server to re-probe harness authentication, then invalidates
    /// every mounted consumer of that machine's catalog.
    public func refreshHarnessAuthentication() async throws -> [ServerHarness] {
        // Snapshot before awaiting so a machine switch cannot attribute the
        // completed request to whichever machine happens to be selected later.
        let serverId = machines.selectedMachineId
        let refreshed = try await machines.client(for: serverId).refreshHarnessAuth()
        harnessCatalogDidChange(onServer: serverId)
        return refreshed
    }

    /// Re-probes only the harness whose authentication changed, then
    /// invalidates mounted consumers of that machine's catalog.
    public func refreshHarnessAuthentication(harnessId: String) async throws -> ServerHarness {
        let serverId = machines.selectedMachineId
        let refreshed = try await machines.client(for: serverId).refreshHarnessAuth(harnessId: harnessId)
        harnessCatalogDidChange(onServer: serverId)
        return refreshed
    }

    /// Deletes all Codevisor data (projects, sessions, cached config, settings)
    /// and re-triggers onboarding. Does not touch the harnesses' own sessions.
    public func deleteAllData() {
        AnalyticsClient.shared.setEnabled(false)
        projectList.removeAll()
        configCache.clear()
        composerDefaults.clear()
        composerDrafts.clear()
        settings.reset()
        appUpdate.setAllowsPrereleaseUpdates(settings.betaUpdatesEnabled)
        projectList.showsImportedSessions = settings.importExternalSessions
    }

    /// Persists analytics consent and immediately applies it to the delivery
    /// client. This is the only path the onboarding and Settings UI use.
    public func setShareAnalytics(_ enabled: Bool) {
        settings.setShareAnalytics(enabled)
        AnalyticsClient.shared.setEnabled(enabled)
    }

    /// Changes update channels immediately; the Settings view follows this
    /// with a fresh check so enabling or disabling beta updates updates the
    /// banner without requiring a relaunch.
    public func setBetaUpdatesEnabled(_ enabled: Bool) {
        settings.setBetaUpdatesEnabled(enabled)
        appUpdate.setAllowsPrereleaseUpdates(enabled)
    }

    /// Applies the user's onboarding choice and imports if requested.
    public func finishOnboarding(importExternalSessions: Bool) async {
        settings.completeOnboarding(importExternalSessions: importExternalSessions)
        projectList.showsImportedSessions = importExternalSessions
        if importExternalSessions {
            await importSessions()
        }
    }

    /// Completes onboarding, importing if requested, and adds the chosen project
    /// folder as a project. Returns the new project so the caller can open a
    /// new chat in it.
    @discardableResult
    public func finishOnboarding(importExternalSessions: Bool, projectFolder: URL?) async -> Project? {
        await finishOnboarding(importExternalSessions: importExternalSessions)
        guard let projectFolder else { return nil }
        return projectList.addProject(folderURL: projectFolder)
    }

    /// Completes onboarding for the chosen project folders: adds each as a
    /// project and returns the first so the caller can open a new chat in it.
    /// Existing agent chats are deliberately NOT pulled in here — a first
    /// project pre-filled with old CLI sessions the user never asked for
    /// reads as clutter; importing stays an explicit action.
    @discardableResult
    public func finishOnboarding(projectFolders: [URL]) async -> Project? {
        settings.completeOnboarding(importExternalSessions: false)
        projectList.showsImportedSessions = settings.importExternalSessions
        var first: Project?
        for folder in projectFolders {
            let project = projectList.addProject(folderURL: folder)
            if first == nil { first = project }
        }
        return first
    }

    /// Single-folder convenience over `finishOnboarding(projectFolders:)`.
    @discardableResult
    public func finishOnboarding(projectFolder: URL) async -> Project {
        // The array overload always returns a project for a non-empty list.
        await finishOnboarding(projectFolders: [projectFolder])!
    }

    /// Frozen at the first GitHub-aware release so older apps can cross the
    /// update-source migration. It is only consulted if GitHub is unavailable.
    public static let legacyReleaseArtifactBaseURL = URL(
        string: "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"
    )!

    public static func live() -> AppEnvironment {
        CodevisorAppVariant.migrateLegacyApplicationSupportIfNeeded()
        let store = FileSystemStore(directory: CodevisorAppVariant.applicationSupportURL())
        let settings = AppSettingsModel(store: store)
        let serverClient = CodevisorServerClient(config: .localDefault)
        let localServer = LocalCodevisorServer(client: serverClient)
        return AppEnvironment(
            projectRepository: DefaultProjectRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: store),
            configCache: ConfigOptionCache(store: store),
            composerDefaults: ComposerDefaultsStore(store: store),
            composerDrafts: ComposerDraftStore(store: store),
            settings: settings,
            machineStore: store,
            legacyCacheMigrationStore: store,
            paneGroups: DefaultPaneGroupRepository(store: store),
            workspaces: DefaultWorkspaceRepository(store: store),
            scratchpads: DefaultScratchpadRepository(store: store),
            localServer: localServer,
            appUpdate: AppUpdateModel(
                currentVersion: AppUpdateModel.bundleVersion(),
                currentReleaseChannel: AppUpdateModel.bundleReleaseChannel(),
                currentBuildNumber: AppUpdateModel.bundleBuildNumber(),
                checker: FallbackAppUpdateChecker(
                    primary: GitHubAppUpdateChecker(),
                    fallback: ManifestAppUpdateChecker(baseURL: legacyReleaseArtifactBaseURL)
                ),
                prereleaseChecker: FallbackAppUpdateChecker(
                    primary: GitHubAppUpdateChecker(includesPrereleases: true),
                    fallback: ManifestAppUpdateChecker(baseURL: legacyReleaseArtifactBaseURL)
                ),
                allowsPrereleaseUpdates: settings.betaUpdatesEnabled
            ),
            customThemesDirectory: ThemeManager.defaultCustomThemesDirectory()
        )
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
        if hasOnboarded { settings.completeOnboarding(importExternalSessions: false) }
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
        Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/Codevisor"), createdAt: Date(timeIntervalSince1970: 2_000)),
        Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/website"), createdAt: Date(timeIntervalSince1970: 1_000)),
        // No sessions reference this one, so previews exercise the
        // "No sessions yet" empty state.
        Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/scratch"), createdAt: Date(timeIntervalSince1970: 750)),
        archivedSampleProject
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
        )
    ]

    private static var archivedSampleProject: Project {
        var project = Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/old"), createdAt: Date(timeIntervalSince1970: 500))
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
            )
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
            )
        ]
    }

    public func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
        [
            SessionInfo(sessionId: "ext-1", cwd: "/Users/me/src/website", title: "Fix the landing page"),
            SessionInfo(sessionId: "ext-2", cwd: "/Users/me/src/Codevisor", title: "Add tests")
        ]
    }
}
