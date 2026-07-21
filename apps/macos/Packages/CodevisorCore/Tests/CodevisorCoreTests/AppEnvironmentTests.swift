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
            URL(fileURLWithPath: "/Users/me/src/website")
        ])

        #expect(environment.settings.hasCompletedOnboarding)
        #expect(first?.folderURL.path == "/Users/me/src/website")
        #expect(environment.projectList.projects.map(\.folderURL.path).sorted()
            == ["/Users/me/src/Codevisor", "/Users/me/src/website"])
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
        #expect(environment.workspaces.workspace(id: workspace.id)?.isArchived == false)
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
        #expect(environment.workspaces.workspace(id: workspace.id)?.isArchived == false)
        #expect(environment.archiveSessionAndWorkspaceIfEmpty(second))
        #expect(environment.workspaces.workspace(id: workspace.id)?.isArchived == true)
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

}
