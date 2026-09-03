import Foundation
import Testing

@testable import CodevisorCore

/// The keep/sibling/dismiss policy for a workspace whose chats have all
/// been archived. Nous lists such a workspace by its terminal/plugin tabs,
/// and a session route is the only way to mount it, so the archived chat
/// still routed to it must keep the route — unless nothing but the New
/// Tab placeholder is left.
@MainActor
struct WorkspaceSyncRouteDispositionTests {
  @MainActor
  private struct Fixture {
    let projectId = UUID()
    let sessionId = UUID()
    let workspaceId = UUID()
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )

    func makeSync(layout: [WorkspaceTab]) async -> WorkspaceSyncModel {
      let project = ServerProject(
        id: projectId.uuidString,
        name: "codevisor",
        isArchived: false,
        origin: .codevisor,
        createdAt: "2026-06-30T00:00:00.000Z",
        locations: [
          ServerProjectLocation(
            id: UUID().uuidString,
            projectId: projectId.uuidString,
            serverId: "local",
            folderPath: "/tmp/octopus",
            createdAt: "2026-06-30T00:00:00.000Z",
            isGitRepository: nil
          )
        ]
      )
      let archivedChat = ServerSession(
        id: sessionId.uuidString,
        projectId: projectId.uuidString,
        serverId: "local",
        harnessId: "codex",
        agentSessionId: nil,
        title: "Archived chat",
        origin: .codevisor,
        isArchived: true,
        worktreeName: nil,
        workspaceId: workspaceId.uuidString,
        cwd: "/tmp/octopus",
        createdAt: "2026-06-30T00:00:01.000Z",
        updatedAt: nil,
        usage: nil
      )
      let workspaceRecord = ServerWorkspace(
        id: workspaceId.uuidString,
        serverId: "local",
        projectId: projectId.uuidString,
        name: "octopus",
        hasCustomName: false,
        rootDirectory: "/tmp/octopus",
        isArchived: false,
        createdAt: "2026-06-30T00:00:00.000Z"
      )
      repository.save(
        Workspace(
          id: workspaceId,
          name: "octopus",
          rootDirectory: "/tmp/octopus",
          serverId: "local",
          projectId: projectId,
          centerTabs: layout,
          bottomGroup: PaneGroupState(),
          isServerSynced: true
        )
      )
      let fake = SyncFakeServerClient(
        projects: [project],
        sessions: [archivedChat],
        workspaces: [workspaceRecord]
      )
      let workspaceSync = WorkspaceSyncModel(repository: repository, projectList: projectList)
      let controller = MachineController(
        store: InMemoryStore(),
        projectList: projectList,
        workspaceSync: workspaceSync,
        clientFactory: { _ in fake }
      )
      await controller.refreshNavigationState(for: "local")
      return workspaceSync
    }

    var chatTab: WorkspaceTab {
      let chat = PaneDescriptorState(
        id: sessionId,
        kind: .chat,
        name: "Archived chat",
        terminalKey: sessionId.uuidString,
        chatSessionId: sessionId
      )
      return WorkspaceTab(
        root: .leaf(PaneGroupState(panes: [chat], selectedPaneId: chat.id, isVisible: true))
      )
    }
  }

  @Test("A chat-less workspace with a live terminal keeps its archived anchor route")
  func terminalKeepsArchivedAnchorRoute() async throws {
    let fixture = Fixture()
    let terminal = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "shell"
    )
    let terminalTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id, isVisible: true))
    )
    let sync = await fixture.makeSync(layout: [terminalTab, fixture.chatTab])

    let session = try #require(fixture.projectList.sessions.first { $0.id == fixture.sessionId })
    #expect(session.isArchived)
    #expect(fixture.repository.workspaceId(forSession: fixture.sessionId) == fixture.workspaceId)
    #expect(fixture.repository.workspace(id: fixture.workspaceId)?.hasOpenNonChatContent == true)

    #expect(
      sync.routeDisposition(
        workspaceId: fixture.workspaceId,
        anchorSessionId: fixture.sessionId,
        serverId: "local"
      ) == .keep
    )
    #expect(sync.routeDisposition(sessionId: fixture.sessionId, serverId: "local") == .keep)
  }

  @Test("A workspace left with only the New Tab placeholder dismisses its archived anchor")
  func placeholderOnlyDismissesArchivedAnchor() async throws {
    let fixture = Fixture()
    let placeholderId = UUID()
    let placeholder = PaneDescriptorState(
      id: placeholderId, kind: .newTab, name: "New tab", terminalKey: placeholderId.uuidString
    )
    let placeholderTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [placeholder], selectedPaneId: placeholderId, isVisible: true))
    )
    let sync = await fixture.makeSync(layout: [placeholderTab, fixture.chatTab])

    #expect(fixture.repository.workspace(id: fixture.workspaceId)?.hasOpenNonChatContent == false)
    #expect(
      sync.routeDisposition(
        workspaceId: fixture.workspaceId,
        anchorSessionId: fixture.sessionId,
        serverId: "local"
      ) == .dismiss
    )
    #expect(sync.routeDisposition(sessionId: fixture.sessionId, serverId: "local") == .dismiss)
  }

  @Test("An archived chat that is not routed to the workspace does not keep it")
  func unroutedAnchorDismisses() async throws {
    let fixture = Fixture()
    let terminal = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "shell"
    )
    let terminalTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id, isVisible: true))
    )
    let sync = await fixture.makeSync(layout: [terminalTab])

    #expect(
      sync.routeDisposition(
        workspaceId: fixture.workspaceId,
        anchorSessionId: UUID(),
        serverId: "local"
      ) == .dismiss
    )
  }
}
