import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension MachineControllerTests {
    @Test("Server pane snapshots materialize remote tabs and apply live deletion")
    func workspacePaneSync() async throws {
        let projectId = UUID()
        let workspaceId = UUID()
        let sessionId = UUID()
        let chatPaneId = UUID()
        let remoteTabId = UUID()
        let project = ServerProject(
            id: projectId.uuidString,
            name: "Shared",
            isArchived: false,
            origin: .codevisor,
            createdAt: "2026-06-30T00:00:00.000Z",
            locations: [
                ServerProjectLocation(
                    id: UUID().uuidString,
                    projectId: projectId.uuidString,
                    serverId: "local",
                    folderPath: "/tmp/shared-panes",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    isGitRepository: nil
                )
            ]
        )
        let session = ServerSession(
            id: sessionId.uuidString,
            projectId: projectId.uuidString,
            serverId: "local",
            harnessId: "codex",
            agentSessionId: nil,
            title: "Chat",
            origin: .codevisor,
            isArchived: false,
            worktreeName: nil,
            workspaceId: workspaceId.uuidString,
            cwd: "/tmp/shared-panes",
            createdAt: "2026-06-30T00:00:01.000Z",
            updatedAt: nil,
            usage: nil
        )
        let workspace = ServerWorkspace(
            id: workspaceId.uuidString,
            serverId: "local",
            projectId: projectId.uuidString,
            name: "Shared",
            hasCustomName: false,
            rootDirectory: "/tmp/shared-panes",
            isArchived: false,
            createdAt: "2026-06-30T00:00:00.000Z"
        )
        let chatPane = ServerWorkspacePane(
            id: chatPaneId.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "chat",
            title: "Chat",
            resourceKind: "session",
            resourceId: sessionId.uuidString,
            createdAt: "2026-06-30T00:00:01.000Z"
        )
        let remoteTab = ServerWorkspacePane(
            id: remoteTabId.uuidString,
            workspaceId: workspaceId.uuidString,
            providerId: "codevisor",
            paneType: "new-tab",
            title: "New tab",
            createdAt: "2026-06-30T00:00:02.000Z"
        )
        let fake = SyncFakeServerClient(
            projects: [project], sessions: [session], workspaces: [workspace],
            panes: [chatPane, remoteTab]
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        var legacyState = PaneGroupState.centerInitial(sessionId: sessionId)
        _ = legacyState.addChatPane(sessionId: sessionId)
        let legacyPane = legacyState.addNewTabPane()
        repository.save(
            Workspace(
                id: workspaceId,
                name: "Shared",
                rootDirectory: "/tmp/shared-panes",
                serverId: "local",
                projectId: projectId,
                centerTree: .leaf(legacyState),
                bottomGroup: PaneGroupState(),
                isServerSynced: false
            )
        )
        let workspaceSync = WorkspaceSyncModel(repository: repository, projectList: projectList)
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            workspaceSync: workspaceSync,
            clientFactory: { _ in fake }
        )

        await controller.refreshNavigationState(for: "local")
        let materialized = try #require(repository.workspace(id: workspaceId))
        #expect(materialized.tabId(containingPane: remoteTabId) != nil)
        #expect(materialized.pane(containingChat: sessionId)?.id == chatPaneId)
        #expect(
            materialized.centerTabs.flatMap { $0.root.allGroups }.flatMap(\.state.panes)
                .filter { $0.chatSessionId == sessionId }.count == 1
        )
        // A coherent current-server snapshot is authoritative: hydration does
        // not upload a local-only fallback pane.
        #expect(fake.workspacePanes?.contains(where: { $0.id == legacyPane.id.uuidString }) == false)

        controller.startEventSync(for: "local")
        fake.setPanes([chatPane])
        fake.emit(kind: "workspace.pane.deleted", subjectId: remoteTabId.uuidString)
        try await waitForSync {
            repository.workspace(id: workspaceId)?.tabId(containingPane: remoteTabId) == nil
        }
    }

    @Test("New workspace adoption preserves pane identity across a coherent refresh")
    func legacyWorkspacePaneAdoption() async throws {
        let projectId = UUID()
        let workspaceId = UUID()
        let sessionId = UUID()
        let project = ServerProject(
            id: projectId.uuidString,
            name: "Legacy",
            isArchived: false,
            origin: .codevisor,
            createdAt: "2026-06-30T00:00:00.000Z",
            locations: [
                ServerProjectLocation(
                    id: UUID().uuidString,
                    projectId: projectId.uuidString,
                    serverId: "local",
                    folderPath: "/tmp/legacy-workspace",
                    createdAt: "2026-06-30T00:00:00.000Z",
                    isGitRepository: nil
                )
            ]
        )
        let session = ServerSession(
            id: sessionId.uuidString,
            projectId: projectId.uuidString,
            serverId: "local",
            harnessId: "codex",
            agentSessionId: nil,
            title: "Legacy chat",
            origin: .codevisor,
            isArchived: false,
            worktreeName: nil,
            workspaceId: nil,
            cwd: "/tmp/legacy-workspace",
            createdAt: "2026-06-30T00:00:01.000Z",
            updatedAt: nil,
            usage: nil
        )
        let fake = SyncFakeServerClient(
            projects: [project], sessions: [session], workspaces: [], panes: []
        )
        let projectList = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
        let repository = DefaultWorkspaceRepository(store: InMemoryStore())
        var chatState = PaneGroupState.centerInitial(sessionId: sessionId)
        let chatPaneId = try #require(
            chatState.panes.first(where: { $0.chatSessionId == sessionId })?.id
        )
        let placeholder = chatState.addNewTabPane()
        repository.save(
            Workspace(
                id: workspaceId,
                name: "Legacy",
                rootDirectory: "/tmp/legacy-workspace",
                serverId: "local",
                projectId: projectId,
                centerTree: .leaf(chatState),
                bottomGroup: PaneGroupState(),
                isServerSynced: false
            )
        )
        let workspaceSync = WorkspaceSyncModel(repository: repository, projectList: projectList)
        let controller = MachineController(
            store: InMemoryStore(),
            projectList: projectList,
            workspaceSync: workspaceSync,
            clientFactory: { _ in fake }
        )

        await controller.refreshNavigationState(for: "local")

        #expect(fake.workspaces.contains { UUID(uuidString: $0.id) == workspaceId })
        #expect(
            fake.sessions.first { UUID(uuidString: $0.id) == sessionId }?.workspaceId
                .flatMap(UUID.init(uuidString:)) == workspaceId
        )
        #expect(fake.workspacePanes?.contains { UUID(uuidString: $0.id) == chatPaneId } == true)
        #expect(fake.workspacePanes?.contains { UUID(uuidString: $0.id) == placeholder.id } == true)
        #expect(fake.workspacePanes?.contains { UUID(uuidString: $0.id) == sessionId } == false)
        #expect(repository.workspace(id: workspaceId)?.pane(containingChat: sessionId)?.id == chatPaneId)
        #expect(repository.workspace(id: workspaceId)?.tabId(containingPane: placeholder.id) != nil)
        #expect(repository.workspace(id: workspaceId)?.isServerSynced == true)
        #expect(fake.workspaceSnapshotCallCount == 2)
    }
}
