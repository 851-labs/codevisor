import Foundation
import Testing

@testable import CodevisorCore

/// The keep/sibling/dismiss policy for a workspace whose chats are all
/// CLOSED — they still belong to it, but none of them has a pane. The
/// sidebar lists such a workspace by its terminal/plugin tabs, and a session
/// route is the only way to mount it, so the closed chat still assigned to it
/// must keep the route — unless nothing but the New Tab placeholder is left.
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
        title: "Closed chat",
        origin: .codevisor,
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
          isServerSynced: true
        )
      )
      let fake = SyncFakeServerClient(
        projects: [project],
        sessions: [archivedChat],
        workspaces: [workspaceRecord],
        panes: layout.flatMap { $0.root.allGroups }.flatMap(\.state.panes).map {
          WorkspaceSyncModel.serverPane(from: $0, workspaceId: workspaceId, createdAt: Date(timeIntervalSince1970: 0))
        }
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

    /// The chat tab that seeds the session index, exactly as an open chat
    /// would. `closeChatTab` then removes it: the index only grows, so the
    /// chat keeps pointing at this workspace after its tab is gone -- which
    /// is what "closed" means and what the route still anchors on.
    var chatTab: WorkspaceTab {
      let chat = PaneDescriptorState(
        id: sessionId,
        kind: .chat,
        name: "Closed chat",
        terminalKey: sessionId.uuidString,
        chatSessionId: sessionId
      )
      return WorkspaceTab(
        root: .leaf(PaneGroupState(panes: [chat], selectedPaneId: chat.id))
      )
    }

    func closeChatTab(keeping remaining: [WorkspaceTab]) {
      guard var workspace = repository.workspace(id: workspaceId) else { return }
      workspace.centerTabs = remaining
      workspace.selectedCenterTabId = remaining[0].id
      repository.save(workspace)
    }
  }

  @Test("A chat-less workspace with a live terminal keeps its closed anchor route")
  func terminalKeepsClosedAnchorRoute() async throws {
    let fixture = Fixture()
    let terminal = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "shell"
    )
    let terminalTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id))
    )
    let sync = await fixture.makeSync(layout: [terminalTab, fixture.chatTab])
    // Closing the chat's tab is the whole of "this chat is closed": the chat
    // row and its workspace membership are untouched.
    fixture.closeChatTab(keeping: [terminalTab])

    #expect(fixture.projectList.sessions.contains { $0.id == fixture.sessionId })
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

  @Test("A workspace left with only the New Tab placeholder dismisses its closed anchor")
  func placeholderOnlyDismissesClosedAnchor() async throws {
    let fixture = Fixture()
    let placeholderId = UUID()
    let placeholder = PaneDescriptorState(
      id: placeholderId, kind: .newTab, name: "New tab", terminalKey: placeholderId.uuidString
    )
    let placeholderTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [placeholder], selectedPaneId: placeholderId))
    )
    let sync = await fixture.makeSync(layout: [placeholderTab, fixture.chatTab])
    fixture.closeChatTab(keeping: [placeholderTab])

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

  @Test("A closed chat that is not assigned to the workspace does not keep it")
  func unroutedAnchorDismisses() async throws {
    let fixture = Fixture()
    let terminal = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Terminal 1", terminalKey: "shell"
    )
    let terminalTab = WorkspaceTab(
      root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id))
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
