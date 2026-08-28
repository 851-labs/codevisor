import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("AppEnvironment and harness services")
struct AppEnvironmentTests {
    @Test("Debug builds use isolated development defaults")
    func debugVariantDefaults() {
        #if DEBUG
            #expect(CodevisorAppVariant.isDevelopment)
            #expect(CodevisorAppVariant.localServerPort == CodevisorAppVariant.developmentPort)
            #expect(CodevisorAppVariant.applicationSupportDirectoryName == "Codevisor Development")
        #else
            #expect(!CodevisorAppVariant.isDevelopment)
            #expect(CodevisorAppVariant.localServerPort == CodevisorAppVariant.productionPort)
            #expect(CodevisorAppVariant.applicationSupportDirectoryName == "Codevisor")
        #endif
    }

    @Test("Preview environment seeds sample projects")
    func previewSeed() {
        let environment = AppEnvironment.preview()
        #expect(environment.projectList.projects.count == AppEnvironment.sampleProjects.count)
        #expect(environment.projectList.hasArchivedProjects)
    }

    @Test("Preview environment can use a custom seed")
    func customSeed() {
        let environment = AppEnvironment.preview(seedProjects: [])
        #expect(environment.projectList.projects.isEmpty)
    }

    @Test("Preview harness service returns sample harnesses")
    func previewHarnessService() async throws {
        let service = PreviewHarnessService()
        let ready = await service.readyHarnesses()
        #expect(ready.contains { $0.id == "claude-code" })
        let all = await service.allHarnesses()
        #expect(all.count > ready.count)
        #expect(all.contains { !$0.isReady })
    }

    @Test("Harness catalog invalidation is isolated per machine")
    func harnessCatalogInvalidation() {
        let environment = AppEnvironment.preview()

        #expect(environment.harnessCatalogRevision(for: "local") == 0)
        #expect(environment.harnessCatalogRevision(for: "remote") == 0)

        environment.harnessCatalogDidChange(onServer: "local")
        environment.harnessCatalogDidChange(onServer: "local")

        #expect(environment.harnessCatalogRevision(for: "local") == 2)
        #expect(environment.harnessCatalogRevision(for: "remote") == 0)
    }

    @Test("Plugin update revisions are isolated per machine and per plugin")
    func pluginUpdateRevisionInvalidation() {
        let environment = AppEnvironment.preview()

        #expect(environment.pluginUpdateRevision(forServer: "local", pluginId: "owner.a") == 0)

        environment.pluginDidUpdate(onServer: "local", pluginId: "owner.a")
        environment.pluginDidUpdate(onServer: "local", pluginId: "owner.a")

        // Only the restarted/re-imported plugin's panes reload; a different
        // plugin (or the same plugin on another machine) stays put.
        #expect(environment.pluginUpdateRevision(forServer: "local", pluginId: "owner.a") == 2)
        #expect(environment.pluginUpdateRevision(forServer: "local", pluginId: "owner.b") == 0)
        #expect(environment.pluginUpdateRevision(forServer: "remote", pluginId: "owner.a") == 0)

        // The machine-scoped plugin-state revision is a separate channel:
        // runtime-state chips must never trigger pane reloads.
        #expect(environment.pluginStateRevision(for: "local") == 0)
    }

    @Test("Harness operation response closes the lifecycle handoff gap")
    func harnessLifecycleHandoff() async {
        let environment = AppEnvironment.preview()
        await environment.refreshHarnessLifecycle(for: "local")
        let lifecycle = ServerHarnessLifecycleState(
            phase: "updating",
            targetVersion: "2.0.0",
            terminalId: "terminal-1"
        )

        environment.setHarnessLifecycle(
            lifecycle,
            harnessId: "claude-code",
            onServer: "local"
        )

        #expect(
            environment.harnessLifecycle(for: "local")
                .first(where: { $0.id == "claude-code" })?.lifecycle == lifecycle
        )
    }

    @Test("Onboarding with a project folder adds the project without importing old chats")
    func onboardingImportsProjectSessions() async {
        let environment = AppEnvironment.preview(seedProjects: [], hasOnboarded: false)

        // PreviewHarnessService reports importable sessions for this folder,
        // but onboarding must NOT pull them in — the first project opens
        // fresh; importing old chats stays an explicit user action.
        let project = await environment.finishOnboarding(
            projectFolder: URL(fileURLWithPath: "/Users/me/src/website")
        )

        #expect(environment.settings.hasCompletedOnboarding)
        #expect(!environment.settings.importExternalSessions)
        #expect(!environment.projectList.showsImportedSessions)
        #expect(environment.projectList.sessions(in: project).isEmpty)
    }

    @Test("Onboarding with multiple folders adds every project and returns the first")
    func onboardingAddsMultipleProjects() async {
        let environment = AppEnvironment.preview(seedProjects: [], hasOnboarded: false)

        let first = await environment.finishOnboarding(projectFolders: [
            URL(fileURLWithPath: "/Users/me/src/website"),
            URL(fileURLWithPath: "/Users/me/src/Codevisor"),
            // Duplicates collapse into the existing project.
            URL(fileURLWithPath: "/Users/me/src/website"),
        ])

        #expect(environment.settings.hasCompletedOnboarding)
        #expect(first?.folderURL.path == "/Users/me/src/website")
        #expect(
            environment.projectList.projects.map(\.folderURL.path).sorted()
                == ["/Users/me/src/Codevisor", "/Users/me/src/website"])
    }

    @Test("Onboarding publishes completion after registering projects")
    func onboardingPublishesCompletionLast() async {
        let events = OnboardingCompletionEvents()
        let environment = AppEnvironment(
            projectRepository: OnboardingProjectRepository(events: events),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            configCache: ConfigOptionCache(store: InMemoryStore()),
            settings: AppSettingsModel(
                store: OnboardingSettingsStore(events: events)
            )
        )

        _ = await environment.finishOnboarding(projectFolders: [
            URL(fileURLWithPath: "/Users/me/src/website")
        ])

        #expect(events.snapshot == ["projects registered", "onboarding completed"])
    }

    @Test("Importable sessions are scoped to the folder and exclude known ones")
    func importableSessionsScopedToFolder() async {
        let environment = AppEnvironment.preview(seedProjects: [])

        let found = await environment.findImportableSessions(
            for: URL(fileURLWithPath: "/Users/me/src/website")
        )
        #expect(found.map(\.info.sessionId) == ["ext-1", "ext-1"])
        #expect(found.allSatisfy { $0.info.cwd == "/Users/me/src/website" })

        // Once imported, the same discovery is no longer offered.
        let project = environment.projectList.addProject(
            folderURL: URL(fileURLWithPath: "/Users/me/src/website")
        )
        environment.importSessions(found, into: project)
        #expect(environment.settings.importExternalSessions)
        let remaining = await environment.findImportableSessions(
            for: URL(fileURLWithPath: "/Users/me/src/website")
        )
        #expect(remaining.isEmpty)
    }

    @Test("Project recommendations come from recent harness sessions")
    func projectRecommendations() async {
        let environment = AppEnvironment.preview(seedProjects: [])

        // PreviewHarnessService's sessions live in folders that don't exist on
        // the test machine, so the default directory filter drops them.
        let recommendations = await environment.recommendedProjects()

        #expect(recommendations.isEmpty)
    }

    @Test("Archiving a chat from a tab preserves its workspace")
    func archivingChatPreservesWorkspace() {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/preserve-workspace"))
        let session = ChatSession(projectId: project.id, harnessId: "codex", title: "Chat")
        let environment = AppEnvironment.preview(seedProjects: [project], seedSessions: [session])
        let workspace = environment.workspaces.ensureWorkspace(
            for: WorkspaceSessionSeed(
                sessionId: session.id,
                initialName: project.name,
                serverId: session.serverId,
                projectId: session.projectId,
                rootDirectory: project.folderURL.path
            ),
            legacyGroups: nil
        )

        environment.archiveSession(session)

        #expect(environment.projectList.sessions.first?.isArchived == true)
        let retainedWorkspace = environment.workspaces.workspace(id: workspace.id)
        #expect(retainedWorkspace?.isArchived == false)
        #expect(retainedWorkspace?.pane(containingChat: session.id) == nil)
        #expect(retainedWorkspace?.centerTree.allGroups[0].state.selectedPane?.kind == .newTab)
    }

    @Test("Sidebar archiving the final active chat archives its workspace")
    func sidebarArchivingFinalChatArchivesWorkspace() {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/archive-workspace"))
        let first = ChatSession(projectId: project.id, harnessId: "codex", title: "First")
        let second = ChatSession(projectId: project.id, harnessId: "codex", title: "Second")
        let environment = AppEnvironment.preview(
            seedProjects: [project],
            seedSessions: [first, second]
        )
        var workspace = environment.workspaces.ensureWorkspace(
            for: WorkspaceSessionSeed(
                sessionId: first.id,
                initialName: project.name,
                serverId: first.serverId,
                projectId: first.projectId,
                rootDirectory: project.folderURL.path
            ),
            legacyGroups: nil
        )
        let groupId = workspace.centerTree.allGroups[0].id
        workspace.centerTree = workspace.centerTree.updatingGroup(id: groupId) { group in
            var group = group
            group.addChatPane(sessionId: second.id, name: second.title)
            return group
        }
        environment.workspaces.save(workspace)

        #expect(!environment.archiveSessionAndWorkspaceIfEmpty(first))
        let afterFirstArchive = environment.workspaces.workspace(id: workspace.id)
        #expect(afterFirstArchive?.isArchived == false)
        #expect(afterFirstArchive?.pane(containingChat: first.id) == nil)
        #expect(afterFirstArchive?.pane(containingChat: second.id) != nil)
        #expect(environment.archiveSessionAndWorkspaceIfEmpty(second))
        let afterFinalArchive = environment.workspaces.workspace(id: workspace.id)
        #expect(afterFinalArchive?.isArchived == true)
        #expect(afterFinalArchive?.pane(containingChat: second.id) != nil)
        #expect(environment.projectList.sessions.allSatisfy { $0.isArchived })
    }

    @Test("Archiving a workspace archives each of its active chats")
    func archivingWorkspaceArchivesChats() {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/archive-workspace"))
        let session = ChatSession(projectId: project.id, harnessId: "codex", title: "Chat")
        let environment = AppEnvironment.preview(seedProjects: [project], seedSessions: [session])
        let workspace = environment.workspaces.ensureWorkspace(
            for: WorkspaceSessionSeed(
                sessionId: session.id,
                initialName: project.name,
                serverId: session.serverId,
                projectId: session.projectId,
                rootDirectory: project.folderURL.path
            ),
            legacyGroups: nil
        )

        environment.archiveWorkspace(workspace)

        #expect(environment.workspaces.workspace(id: workspace.id)?.isArchived == true)
        #expect(environment.projectList.sessions.first?.isArchived == true)
    }

    @Test("Restoring a workspace clears its archived flag")
    func unarchivingWorkspaceRestoresIt() {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/unarchive-workspace"))
        let session = ChatSession(projectId: project.id, harnessId: "codex", title: "Chat")
        let environment = AppEnvironment.preview(seedProjects: [project], seedSessions: [session])
        let workspace = environment.workspaces.ensureWorkspace(
            for: WorkspaceSessionSeed(
                sessionId: session.id,
                initialName: project.name,
                serverId: session.serverId,
                projectId: session.projectId,
                rootDirectory: project.folderURL.path
            ),
            legacyGroups: nil
        )

        environment.archiveWorkspace(workspace)
        #expect(environment.workspaces.workspace(id: workspace.id)?.isArchived == true)

        guard let archived = environment.workspaces.workspace(id: workspace.id) else {
            Issue.record("Workspace vanished after archiving")
            return
        }
        environment.unarchiveWorkspace(archived)

        // Pane layout is retained across the round trip — restoring must give
        // back the same surface, not a fresh empty one.
        let restored = environment.workspaces.workspace(id: workspace.id)
        #expect(restored?.isArchived == false)
        #expect(restored?.id == workspace.id)
        #expect(restored?.name == workspace.name)
    }
}

private final class OnboardingCompletionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var snapshot: [String] { lock.withLock { events } }

    func record(_ event: String) {
        lock.withLock { events.append(event) }
    }
}

private struct OnboardingProjectRepository: ProjectRepository {
    let events: OnboardingCompletionEvents

    func load() -> [Project] { [] }

    func save(_ projects: [Project]) {
        if !projects.isEmpty { events.record("projects registered") }
    }
}

private final class OnboardingSettingsStore: PersistenceStore, @unchecked Sendable {
    private let backing = InMemoryStore()
    private let events: OnboardingCompletionEvents

    init(events: OnboardingCompletionEvents) {
        self.events = events
    }

    func loadData(forKey key: String) -> Data? {
        backing.loadData(forKey: key)
    }

    func saveData(_ data: Data, forKey key: String) throws {
        try backing.saveData(data, forKey: key)
        guard key == "settings",
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
            settings.hasCompletedOnboarding
        else { return }
        events.record("onboarding completed")
    }

    func removeData(forKey key: String) throws {
        try backing.removeData(forKey: key)
    }
}
