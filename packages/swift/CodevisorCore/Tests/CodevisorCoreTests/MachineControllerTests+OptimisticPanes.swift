import Foundation
import Testing
import CodevisorTestSupport
import ACPKit
@testable import CodevisorCore

@MainActor
extension MachineControllerTests {
  @Test("A stale placeholder snapshot cannot repaint an optimistic chat promotion")
  func staleWorkspacePaneSnapshotDoesNotRevertPromotion() async throws {
    let projectId = UUID()
    let workspaceId = UUID()
    let sessionId = UUID()
    let paneId = UUID()
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
          folderPath: "/tmp/stale-pane",
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
      title: "New Chat",
      origin: .codevisor,
      isArchived: false,
      worktreeName: nil,
      workspaceId: workspaceId.uuidString,
      cwd: "/tmp/stale-pane",
      createdAt: "2026-06-30T00:00:01.000Z",
      updatedAt: nil,
      usage: nil
    )
    let workspaceRecord = ServerWorkspace(
      id: workspaceId.uuidString,
      serverId: "local",
      projectId: projectId.uuidString,
      name: "Shared",
      hasCustomName: false,
      rootDirectory: "/tmp/stale-pane",
      isArchived: false,
      createdAt: "2026-06-30T00:00:00.000Z"
    )
    let placeholderRecord = ServerWorkspacePane(
      id: paneId.uuidString,
      workspaceId: workspaceId.uuidString,
      providerId: "codevisor",
      paneType: "new-tab",
      title: "New tab",
      revision: 1,
      createdAt: "2026-06-30T00:00:02.000Z"
    )
    let fake = SyncFakeServerClient(
      projects: [project],
      sessions: [session],
      workspaces: [workspaceRecord],
      panes: [placeholderRecord]
    )
    fake.panePromotionGate = TestSignal()
    defer { fake.panePromotionGate?.signal() }
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let placeholder = PaneDescriptorState(
      id: paneId,
      kind: .newTab,
      name: "New tab",
      terminalKey: paneId.uuidString
    )
    repository.save(
      Workspace(
        id: workspaceId,
        name: "Shared",
        rootDirectory: "/tmp/stale-pane",
        serverId: "local",
        projectId: projectId,
        centerTree: .leaf(
          PaneGroupState(
            panes: [placeholder], selectedPaneId: paneId, isVisible: true
          )
        ),
        bottomGroup: PaneGroupState(),
        isServerSynced: true
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
    let localSession = try #require(projectList.sessions.first { $0.id == sessionId })
    let promoted = PaneDescriptorState(
      id: paneId,
      kind: .chat,
      name: "New Chat",
      terminalKey: paneId.uuidString,
      chatSessionId: sessionId
    )
    var localWorkspace = try #require(repository.workspace(id: workspaceId))
    localWorkspace.upsertCenterPane(promoted)
    repository.save(localWorkspace)

    workspaceSync.promotePaneToChat(
      promoted,
      session: localSession,
      workspaceId: workspaceId,
      client: fake
    )
    await fake.panePromotionStarted.wait()
    // This response is deliberately captured while the server still has
    // revision 1 / New Tab. It must not overwrite the local renderer.
    await workspaceSync.refreshFromServer(serverId: "local", client: fake)
    #expect(repository.workspace(id: workspaceId)?.pane(containingChat: sessionId)?.id == paneId)

    fake.panePromotionGate?.signal()
    try await waitForSync {
      fake.workspacePanes?.first?.paneType == "chat"
        && repository.workspace(id: workspaceId)?.pane(containingChat: sessionId)?.id == paneId
    }
  }

  @Test("Optimistic pane closes reject stale snapshots and preserve the final pane id")
  func optimisticWorkspacePaneClose() async throws {
    let projectId = UUID()
    let workspaceId = UUID()
    let firstId = UUID()
    let secondId = UUID()
    let workspaceRecord = ServerWorkspace(
      id: workspaceId.uuidString,
      serverId: "local",
      projectId: projectId.uuidString,
      name: "Shared",
      hasCustomName: false,
      rootDirectory: "/tmp/optimistic-close",
      isArchived: false,
      createdAt: "2026-06-30T00:00:00.000Z"
    )
    let firstRecord = ServerWorkspacePane(
      id: firstId.uuidString,
      workspaceId: workspaceId.uuidString,
      providerId: "codevisor",
      paneType: "terminal",
      title: "Terminal 1",
      resourceKind: "terminal",
      resourceId: "one",
      revision: 1,
      createdAt: "2026-06-30T00:00:01.000Z"
    )
    let secondRecord = ServerWorkspacePane(
      id: secondId.uuidString,
      workspaceId: workspaceId.uuidString,
      providerId: "codevisor",
      paneType: "terminal",
      title: "Terminal 2",
      resourceKind: "terminal",
      resourceId: "two",
      revision: 1,
      createdAt: "2026-06-30T00:00:02.000Z"
    )
    let fake = SyncFakeServerClient(
      projects: [], sessions: [], workspaces: [workspaceRecord],
      panes: [firstRecord, secondRecord]
    )
    fake.paneCloseGate = TestSignal()
    defer { fake.paneCloseGate?.signal() }
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let first = PaneDescriptorState(
      id: firstId, kind: .terminal, name: "Terminal 1", terminalKey: "one"
    )
    let second = PaneDescriptorState(
      id: secondId, kind: .terminal, name: "Terminal 2", terminalKey: "two"
    )
    var local = Workspace(
      id: workspaceId,
      name: "Shared",
      rootDirectory: "/tmp/optimistic-close",
      serverId: "local",
      projectId: projectId,
      centerTabs: [
        WorkspaceTab(
          root: .leaf(
            PaneGroupState(panes: [first], selectedPaneId: firstId, isVisible: true)
          )
        ),
        WorkspaceTab(
          root: .leaf(
            PaneGroupState(panes: [second], selectedPaneId: secondId, isVisible: true)
          )
        ),
      ],
      bottomGroup: PaneGroupState(),
      isServerSynced: true
    )
    let sync = WorkspaceSyncModel(repository: repository, projectList: projectList)

    // The UI removes the second pane immediately. A snapshot captured
    // while Close is still in flight must not resurrect it.
    local.centerTabs.removeLast()
    local.selectedCenterTabId = local.centerTabs[0].id
    repository.save(local)
    sync.deletePane(id: secondId, workspaceId: workspaceId, client: fake)
    await fake.paneCloseStarted.wait()
    await sync.refreshFromServer(serverId: "local", client: fake)
    #expect(repository.workspace(id: workspaceId)?.tabId(containingPane: secondId) == nil)
    fake.paneCloseGate?.signal()
    try await waitForSync {
      fake.workspacePanes?.contains(where: { UUID(uuidString: $0.id) == secondId }) == false
    }

    // Closing the remaining renderer is an in-place optimistic reset and
    // the server confirms that exact same identity.
    fake.paneCloseGate = nil
    var final = try #require(repository.workspace(id: workspaceId))
    let groupId = try #require(final.centerTabs[0].root.allGroups.first?.id)
    var replacement: PaneDescriptorState?
    final.centerTabs[0].root = final.centerTabs[0].root.updatingGroup(id: groupId) { state in
      var state = state
      replacement = state.replacePaneWithNewTab(id: firstId)
      return state
    }
    repository.save(final)
    sync.deletePane(
      id: firstId,
      workspaceId: workspaceId,
      optimisticReplacement: replacement,
      client: fake
    )
    #expect(repository.workspace(id: workspaceId)?.centerTree.allGroups[0].state.selectedPane?.id == firstId)
    try await waitForSync {
      fake.workspacePanes?.first?.id.caseInsensitiveCompare(firstId.uuidString) == .orderedSame
        && fake.workspacePanes?.first?.paneType == "new-tab"
        && repository.workspace(id: workspaceId)?.centerTree.allGroups[0].state.selectedPane?.kind
          == .newTab
    }
  }

  @Test("An immediate pane close reaches the server after its create")
  func immediateWorkspacePaneClosePreservesCommandOrder() async throws {
    let projectId = UUID()
    let workspaceId = UUID()
    let paneId = UUID()
    let workspaceRecord = ServerWorkspace(
      id: workspaceId.uuidString,
      serverId: "local",
      projectId: projectId.uuidString,
      name: "Shared",
      hasCustomName: false,
      rootDirectory: "/tmp/ordered-close",
      isArchived: false,
      createdAt: "2026-06-30T00:00:00.000Z"
    )
    let fake = SyncFakeServerClient(
      projects: [], sessions: [], workspaces: [workspaceRecord], panes: []
    )
    fake.paneUpsertGate = TestSignal()
    defer { fake.paneUpsertGate?.signal() }
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    let repository = DefaultWorkspaceRepository(store: InMemoryStore())
    let pane = PaneDescriptorState(
      id: paneId,
      kind: .newTab,
      name: "New tab",
      terminalKey: paneId.uuidString
    )
    repository.save(
      Workspace(
        id: workspaceId,
        name: "Shared",
        rootDirectory: "/tmp/ordered-close",
        serverId: "local",
        projectId: projectId,
        centerTree: .leaf(
          PaneGroupState(panes: [pane], selectedPaneId: paneId, isVisible: true)
        ),
        bottomGroup: PaneGroupState(),
        isServerSynced: true
      )
    )
    let sync = WorkspaceSyncModel(repository: repository, projectList: projectList)

    sync.publishPane(pane, workspaceId: workspaceId, client: fake)
    sync.deletePane(
      id: paneId,
      workspaceId: workspaceId,
      optimisticReplacement: pane,
      client: fake
    )

    await fake.paneUpsertStarted.wait()
    #expect(fake.paneMutationLog == ["upsert"])
    fake.paneUpsertGate?.signal()
    try await waitForSync {
      fake.paneMutationLog == ["upsert", "close"]
        && fake.workspacePanes?.first?.id.caseInsensitiveCompare(paneId.uuidString)
          == .orderedSame
    }
  }

  func waitForSync(_ predicate: () -> Bool) async throws {
    await awaitObserved(predicate)
  }

  // The prepareSelectedMachine + LocalCodevisorServer integration tests
  // (rescan-on-already-running / no-rescan-on-fresh-launch) live in
  // CodevisorCoreMacTests/MachineControllerLocalServerTests.swift: they
  // construct the concrete macOS local server, which is no longer part of
  // this platform-neutral module.

  func makeController(
    store: InMemoryStore = InMemoryStore()
  ) -> (
    controller: MachineController,
    projectList: ProjectListModel,
    store: InMemoryStore
  ) {
    let projectList = ProjectListModel(
      projectRepository: DefaultProjectRepository(store: InMemoryStore()),
      sessionRepository: DefaultSessionRepository(store: InMemoryStore())
    )
    // These tests model the MAC controller: a platform that runs a local
    // server and therefore lists the "Local" machine.
    let controller = MachineController(
      store: store,
      projectList: projectList,
      localServer: StubLocalServer()
    )
    return (controller, projectList, store)
  }
}
