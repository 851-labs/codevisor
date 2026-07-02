import Foundation
import Observation
import ACPKit
import ACPAgents
import HerdManTheming

/// The composition root: wires repositories and services together and vends the
/// top-level view models. Inject a configured instance into the SwiftUI
/// environment; use `preview` for previews and tests.
@MainActor
@Observable
public final class AppEnvironment {
    public let projectList: ProjectListModel
    public let configCache: ConfigOptionCache
    public let settings: AppSettingsModel
    public let theme: ThemeManager
    public let machines: MachineController
    public let localServer: LocalHerdManServer?
    public let appUpdate: AppUpdateModel
    private let fallbackAgentService: any AgentServicing

    public var serverClient: any HerdManServerClienting {
        machines.selectedClient
    }

    public var agentService: any AgentServicing {
        agentService(for: machines.selectedMachineId)
    }

    public var sessionImporter: SessionImporter {
        SessionImporter(agentService: agentService)
    }

    public init(
        projectRepository: any ProjectRepository,
        sessionRepository: any SessionRepository,
        agentService: any AgentServicing,
        configCache: ConfigOptionCache,
        settings: AppSettingsModel,
        machineStore: any PersistenceStore = InMemoryStore(),
        localServer: LocalHerdManServer? = nil,
        appUpdate: AppUpdateModel? = nil,
        customThemesDirectory: URL? = nil
    ) {
        self.fallbackAgentService = agentService
        self.theme = ThemeManager(
            settings: settings,
            catalog: ThemeCatalog(
                customThemesDirectory: customThemesDirectory
                    ?? FileManager.default.temporaryDirectory
                        .appendingPathComponent("herdman-themes-\(UUID().uuidString)")
            )
        )
        self.appUpdate = appUpdate ?? AppUpdateModel(
            currentVersion: AppUpdateModel.bundleVersion(),
            checker: DisabledUpdateChecker()
        )
        self.projectList = ProjectListModel(
            projectRepository: projectRepository,
            sessionRepository: sessionRepository
        )
        self.configCache = configCache
        self.settings = settings
        self.localServer = localServer
        self.machines = MachineController(
            store: machineStore,
            projectList: projectList,
            localServer: localServer
        )
        projectList.showsImportedSessions = settings.importExternalSessions
    }

    /// Refetches sessions from all harnesses and merges them in.
    public func importSessions() async {
        let imported = await sessionImporter.fetchAll()
        projectList.importSessions(imported)
        projectList.showsImportedSessions = settings.importExternalSessions
    }

    /// A couple of project-folder suggestions based on the user's most recent
    /// harness sessions (used by onboarding's project step).
    public func recommendedProjects(limit: Int = 2) async -> [ProjectRecommendation] {
        ProjectRecommender.recommend(from: await sessionImporter.fetchAll(), limit: limit)
    }

    /// Harness sessions whose working directory is the given folder and that
    /// aren't already tracked by HerdMan.
    public func findImportableSessions(for folderURL: URL) async -> [ImportedSession] {
        let folderPath = folderURL.standardizedFileURL.path
        return await sessionImporter.fetchAll().filter { item in
            let matchesFolder = URL(fileURLWithPath: item.info.cwd).standardizedFileURL.path == folderPath
            let alreadyKnown = projectList.sessions.contains {
                $0.harnessId == item.harnessId && $0.agentSessionId == item.info.sessionId
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

    public func agentService(for serverId: String) -> any AgentServicing {
        // The in-process fallback only makes sense for the local machine (e.g.
        // while its server is still starting). A remote machine's harnesses,
        // models, and sessions must come from its server or not at all.
        let isLocal = serverId == HerdManMachine.local.id
        return ServerAgentService(
            client: machines.client(for: serverId),
            fallback: isLocal ? fallbackAgentService : nil
        )
    }

    /// Deletes all HerdMan data (projects, sessions, cached config, settings)
    /// and re-triggers onboarding. Does not touch the harnesses' own sessions.
    public func deleteAllData() {
        projectList.removeAll()
        configCache.clear()
        settings.reset()
        projectList.showsImportedSessions = settings.importExternalSessions
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

    /// Completes onboarding for the chosen project folder: adds the project
    /// and imports any existing harness sessions found in that folder, so the
    /// user's first project starts with their recent chats already in place.
    @discardableResult
    public func finishOnboarding(projectFolder: URL) async -> Project {
        settings.completeOnboarding(importExternalSessions: true)
        projectList.showsImportedSessions = true
        let project = projectList.addProject(folderURL: projectFolder)
        let importable = await findImportableSessions(for: projectFolder)
        projectList.importSessions(importable, into: project)
        return project
    }

    /// The production environment: file-backed persistence and real agent
    /// discovery/launching.
    /// The public artifact bucket that distributes app and server releases —
    /// the same one the Homebrew tap installs from. The source repository is
    /// private, so update checks go through this bucket, not the GitHub API.
    public static let releaseArtifactBaseURL = URL(
        string: "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/herdman"
    )!

    public static func live() -> AppEnvironment {
        let store = FileSystemStore()
        let serverClient = HerdManServerClient(config: .localDefault)
        let localServer = LocalHerdManServer(client: serverClient)
        return AppEnvironment(
            projectRepository: DefaultProjectRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: store),
            agentService: AgentService(),
            configCache: ConfigOptionCache(store: store),
            settings: AppSettingsModel(store: store),
            machineStore: store,
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
        hasOnboarded: Bool = true
    ) -> AppEnvironment {
        let store = InMemoryStore()
        let projectRepository = DefaultProjectRepository(store: store)
        let sessionRepository = DefaultSessionRepository(store: InMemoryStore())
        projectRepository.save(seedProjects)
        let settings = AppSettingsModel(store: InMemoryStore())
        if hasOnboarded { settings.completeOnboarding(importExternalSessions: false) }
        return AppEnvironment(
            projectRepository: projectRepository,
            sessionRepository: sessionRepository,
            agentService: PreviewAgentService(),
            configCache: ConfigOptionCache(store: InMemoryStore()),
            settings: settings,
            machineStore: InMemoryStore()
        )
    }

    public static let sampleProjects: [Project] = [
        Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/HerdMan"), createdAt: Date(timeIntervalSince1970: 2_000)),
        Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/website"), createdAt: Date(timeIntervalSince1970: 1_000)),
        archivedSampleProject
    ]

    private static var archivedSampleProject: Project {
        var project = Project.fromFolder(URL(fileURLWithPath: "/Users/me/src/old"), createdAt: Date(timeIntervalSince1970: 500))
        project.isArchived = true
        return project
    }
}

/// A no-op agent service used in previews.
public struct PreviewAgentService: AgentServicing {
    public init() {}

    public func discoverAgents() async -> [DiscoveredAgent] {
        [
            DiscoveredAgent(id: "claude-code", name: "Claude Code", source: .registry, method: .npx, readiness: .ready, symbolName: "sparkle"),
            DiscoveredAgent(id: "codex", name: "Codex", source: .registry, method: .npx, readiness: .ready, symbolName: "chevron.left.forwardslash.chevron.right")
        ]
    }

    public func discoverAllHarnesses() async -> [DiscoveredAgent] {
        await discoverAgents() + [
            DiscoveredAgent(id: "gemini", name: "Gemini CLI", source: .registry, method: .npx, readiness: .unavailable("Not installed"), symbolName: "diamond"),
            DiscoveredAgent(id: "opencode", name: "OpenCode", source: .registry, method: .executable, readiness: .unavailable("Not installed"), symbolName: "curlybraces"),
            DiscoveredAgent(id: "goose", name: "goose", source: .registry, method: .executable, readiness: .unavailable("Not installed"), symbolName: "bird")
        ]
    }

    public func launch(
        _ agent: DiscoveredAgent,
        workingDirectory: URL,
        delegate: (any ACPClientDelegate)?
    ) async throws -> ACPClient {
        ACPClient(transport: MockTransport(), delegate: delegate)
    }

    public func listSessions(for agent: DiscoveredAgent) async throws -> [SessionInfo] {
        [
            SessionInfo(sessionId: "ext-1", cwd: "/Users/me/src/website", title: "Fix the landing page"),
            SessionInfo(sessionId: "ext-2", cwd: "/Users/me/src/HerdMan", title: "Add tests")
        ]
    }
}
