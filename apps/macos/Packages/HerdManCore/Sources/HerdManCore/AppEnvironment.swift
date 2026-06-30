import Foundation
import Observation
import ACPKit
import ACPAgents

/// The composition root: wires repositories and services together and vends the
/// top-level view models. Inject a configured instance into the SwiftUI
/// environment; use `preview` for previews and tests.
@MainActor
@Observable
public final class AppEnvironment {
    public let workspaceList: WorkspaceListModel
    public let agentService: any AgentServicing
    public let configCache: ConfigOptionCache
    public let settings: AppSettingsModel
    public let sessionImporter: SessionImporter

    public init(
        workspaceRepository: any WorkspaceRepository,
        sessionRepository: any SessionRepository,
        agentService: any AgentServicing,
        configCache: ConfigOptionCache,
        settings: AppSettingsModel,
        serverClient: (any HerdManServerClienting)? = nil
    ) {
        self.workspaceList = WorkspaceListModel(
            workspaceRepository: workspaceRepository,
            sessionRepository: sessionRepository,
            serverClient: serverClient
        )
        self.agentService = agentService
        self.configCache = configCache
        self.settings = settings
        self.sessionImporter = SessionImporter(agentService: agentService)
        workspaceList.showsImportedSessions = settings.importExternalSessions
    }

    /// Refetches sessions from all harnesses and merges them in.
    public func importSessions() async {
        let imported = await sessionImporter.fetchAll()
        workspaceList.importSessions(imported)
        workspaceList.showsImportedSessions = settings.importExternalSessions
    }

    /// Deletes all HerdMan data (workspaces, sessions, cached config, settings)
    /// and re-triggers onboarding. Does not touch the harnesses' own sessions.
    public func deleteAllData() {
        workspaceList.removeAll()
        configCache.clear()
        settings.reset()
        workspaceList.showsImportedSessions = settings.importExternalSessions
    }

    /// Applies the user's onboarding choice and imports if requested.
    public func finishOnboarding(importExternalSessions: Bool) async {
        settings.completeOnboarding(importExternalSessions: importExternalSessions)
        workspaceList.showsImportedSessions = importExternalSessions
        if importExternalSessions {
            await importSessions()
        }
    }

    /// Completes onboarding, importing if requested, and adds the chosen project
    /// folder as a workspace. Returns the new workspace so the caller can open a
    /// new chat in it.
    @discardableResult
    public func finishOnboarding(importExternalSessions: Bool, projectFolder: URL?) async -> Workspace? {
        await finishOnboarding(importExternalSessions: importExternalSessions)
        guard let projectFolder else { return nil }
        return workspaceList.addWorkspace(folderURL: projectFolder)
    }

    /// The production environment: file-backed persistence and real agent
    /// discovery/launching.
    public static func live() -> AppEnvironment {
        let store = FileSystemStore()
        let serverClient = HerdManServerClient(config: .localDefault)
        return AppEnvironment(
            workspaceRepository: DefaultWorkspaceRepository(store: store),
            sessionRepository: DefaultSessionRepository(store: store),
            agentService: ServerAgentService(client: serverClient),
            configCache: ConfigOptionCache(store: store),
            settings: AppSettingsModel(store: store),
            serverClient: serverClient
        )
    }

    /// An in-memory environment seeded with sample data for previews and tests.
    public static func preview(
        seedWorkspaces: [Workspace] = AppEnvironment.sampleWorkspaces,
        hasOnboarded: Bool = true
    ) -> AppEnvironment {
        let store = InMemoryStore()
        let workspaceRepository = DefaultWorkspaceRepository(store: store)
        let sessionRepository = DefaultSessionRepository(store: InMemoryStore())
        workspaceRepository.save(seedWorkspaces)
        let settings = AppSettingsModel(store: InMemoryStore())
        if hasOnboarded { settings.completeOnboarding(importExternalSessions: false) }
        return AppEnvironment(
            workspaceRepository: workspaceRepository,
            sessionRepository: sessionRepository,
            agentService: PreviewAgentService(),
            configCache: ConfigOptionCache(store: InMemoryStore()),
            settings: settings
        )
    }

    public static let sampleWorkspaces: [Workspace] = [
        Workspace(name: "HerdMan", folderURL: URL(fileURLWithPath: "/Users/me/src/HerdMan"), createdAt: Date(timeIntervalSince1970: 2_000)),
        Workspace(name: "website", folderURL: URL(fileURLWithPath: "/Users/me/src/website"), createdAt: Date(timeIntervalSince1970: 1_000)),
        Workspace(name: "old-project", folderURL: URL(fileURLWithPath: "/Users/me/src/old"), isArchived: true, createdAt: Date(timeIntervalSince1970: 500))
    ]
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
