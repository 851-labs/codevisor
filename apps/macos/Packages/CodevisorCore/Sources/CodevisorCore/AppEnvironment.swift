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
    public let settings: AppSettingsModel
    public let theme: ThemeManager
    public let machines: MachineController
    public let localServer: LocalCodevisorServer?
    public let appUpdate: AppUpdateModel
    /// Persists each session's pane-group state (terminal tabs, selection,
    /// panel visibility/height) so panes reattach to their shells after
    /// app restarts.
    public let paneGroups: any PaneGroupRepository
    /// Persists each session's scratchpad (inspector notes + open state).
    public let scratchpads: any ScratchpadRepository
    /// Overrides server-backed harness discovery (previews/tests only).
    private let harnessServiceOverride: (any HarnessServicing)?

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
        settings: AppSettingsModel,
        machineStore: any PersistenceStore = InMemoryStore(),
        legacyCacheMigrationStore: (any PersistenceStore)? = nil,
        paneGroups: any PaneGroupRepository = DefaultPaneGroupRepository(store: InMemoryStore()),
        scratchpads: any ScratchpadRepository = DefaultScratchpadRepository(store: InMemoryStore()),
        localServer: LocalCodevisorServer? = nil,
        appUpdate: AppUpdateModel? = nil,
        customThemesDirectory: URL? = nil,
        harnessService: (any HarnessServicing)? = nil,
        machineClientFactory: MachineController.ClientFactory? = nil
    ) {
        self.harnessServiceOverride = harnessService
        self.paneGroups = paneGroups
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
        self.settings = settings
        self.localServer = localServer
        self.machines = MachineController(
            store: machineStore,
            projectList: projectList,
            localServer: localServer,
            clientFactory: machineClientFactory
        )
        projectList.showsImportedSessions = settings.importExternalSessions
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

    /// Deletes all Codevisor data (projects, sessions, cached config, settings)
    /// and re-triggers onboarding. Does not touch the harnesses' own sessions.
    public func deleteAllData() {
        AnalyticsClient.shared.setEnabled(false)
        projectList.removeAll()
        configCache.clear()
        composerDefaults.clear()
        settings.reset()
        projectList.showsImportedSessions = settings.importExternalSessions
    }

    /// Persists analytics consent and immediately applies it to the delivery
    /// client. This is the only path the onboarding and Settings UI use.
    public func setShareAnalytics(_ enabled: Bool) {
        settings.setShareAnalytics(enabled)
        AnalyticsClient.shared.setEnabled(enabled)
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

    /// The production environment: file-backed persistence and real agent
    /// discovery/launching.
    /// The public artifact bucket that distributes app and server releases —
    /// the same one the Homebrew tap installs from. The source repository is
    /// private, so update checks go through this bucket, not the GitHub API.
    public static let releaseArtifactBaseURL = URL(
        string: "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"
    )!

    public static func live() -> AppEnvironment {
        let store = FileSystemStore(directory: CodevisorAppVariant.applicationSupportURL())
        let serverClient = CodevisorServerClient(config: .localDefault)
        let localServer = LocalCodevisorServer(client: serverClient)
        return AppEnvironment(
            projectRepository: DefaultProjectRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: store),
            configCache: ConfigOptionCache(store: store),
            composerDefaults: ComposerDefaultsStore(store: store),
            settings: AppSettingsModel(store: store),
            machineStore: store,
            legacyCacheMigrationStore: store,
            paneGroups: DefaultPaneGroupRepository(store: store),
            scratchpads: DefaultScratchpadRepository(store: store),
            localServer: localServer,
            appUpdate: AppUpdateModel(
                currentVersion: AppUpdateModel.bundleVersion(),
                checker: ManifestAppUpdateChecker(baseURL: releaseArtifactBaseURL)
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
