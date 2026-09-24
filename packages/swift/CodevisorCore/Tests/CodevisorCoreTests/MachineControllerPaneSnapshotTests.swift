import ACPKit
import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// A machine's pane registry projected onto this device's layout as the
/// controller syncs: snapshots materialize remote panes, live deltas remove
/// them, and this device's own New Tab pages never leave it.
@MainActor
@Suite("MachineController pane snapshots", .timeLimit(.minutes(1)))
struct MachineControllerPaneSnapshotTests {
  private let projectId = UUID()
  private let workspaceId = UUID()
  private let sessionId = UUID()
  private let chatPaneId = UUID()
  private let remoteTabId = UUID()

  private func makeFake() -> SyncFakeServerClient {
    let project = ServerProject(
      id: projectId.uuidString, name: "Shared", origin: .codevisor, createdAt: "2026-06-30T00:00:00.000Z",
      locations: [
        ServerProjectLocation(
          id: UUID().uuidString, projectId: projectId.uuidString, serverId: "local",
          folderPath: "/tmp/shared-panes", createdAt: "2026-06-30T00:00:00.000Z", isGitRepository: nil)
      ])
    let session = ServerSession(
      id: sessionId.uuidString, projectId: projectId.uuidString, serverId: "local", harnessId: "codex",
      agentSessionId: nil, title: "Chat", origin: .codevisor, worktreeName: nil,
      workspaceId: workspaceId.uuidString, cwd: "/tmp/shared-panes", createdAt: "2026-06-30T00:00:01.000Z",
      updatedAt: nil, usage: nil)
    let workspace = ServerWorkspace(
      id: workspaceId.uuidString, serverId: "local", projectId: projectId.uuidString, name: "Shared",
      hasCustomName: false, rootDirectory: "/tmp/shared-panes", isArchived: false,
      createdAt: "2026-06-30T00:00:00.000Z")
    return SyncFakeServerClient(
      projects: [project], sessions: [session], workspaces: [workspace], panes: [chatPane, remoteTab])
  }

  private var chatPane: ServerWorkspacePane {
    ServerWorkspacePane(
      id: chatPaneId.uuidString, workspaceId: workspaceId.uuidString, providerId: "codevisor",
      paneType: "chat", title: "Chat", resourceKind: "session", resourceId: sessionId.uuidString,
      createdAt: "2026-06-30T00:00:01.000Z")
  }

  private var remoteTab: ServerWorkspacePane {
    ServerWorkspacePane(
      id: remoteTabId.uuidString, workspaceId: workspaceId.uuidString, providerId: "codevisor",
      paneType: "browser", title: "Browser", createdAt: "2026-06-30T00:00:02.000Z")
  }

  private func makeController(
    _ navigation: NavigationFixture, fake: SyncFakeServerClient
  ) -> MachineController {
    MachineController(
      store: InMemoryStore(), projectList: navigation.projectList, workspaceSync: navigation.workspaceSync,
      clientFactory: { _ in fake })
  }

  @Test("Server pane snapshots materialize remote tabs, re-key this device's chat pane, and apply live deletion")
  func workspacePaneSync() async throws {
    let fake = makeFake()
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    // This device's layout from before: the chat under an older pane id,
    // a duplicate of it, and a local New Tab page.
    var legacyState = PaneGroupState.centerInitial(sessionId: sessionId)
    _ = legacyState.addChatPane(sessionId: sessionId)
    let localNewTab = legacyState.addNewTabPane()
    let tab = WorkspaceTab(root: .leaf(legacyState))
    navigation.store.layouts.setLayout(
      DeviceLayout(serverId: "local", tabs: [tab], selectedTabId: tab.id), for: workspaceId)
    let controller = makeController(navigation, fake: fake)
    defer { controller.stopEventSync() }

    await controller.refreshNavigationState(for: "local")
    let materialized = try #require(repository.workspace(id: workspaceId))
    #expect(materialized.isServerSynced)
    #expect(materialized.tabId(containingPane: remoteTabId) != nil)
    #expect(materialized.pane(containingChat: sessionId)?.id == chatPaneId)
    #expect(materialized.allPanes.filter { $0.chatSessionId == sessionId }.count == 1)
    // The local New Tab page stays beside the server's panes and is never uploaded.
    #expect(materialized.tabId(containingPane: localNewTab.id) != nil)
    #expect(fake.workspacePanes?.contains(where: { $0.id == localNewTab.id.uuidString }) == false)
    #expect(fake.paneMutationLog.isEmpty)
    #expect(navigation.store.layouts.layout(for: workspaceId)?.tabs == materialized.centerTabs)

    fake.setPanes([chatPane])
    fake.emit(kind: "workspace.pane.deleted", subjectId: remoteTabId.uuidString)
    await awaitObserved {
      _ = navigation.workspaceSync.revision
      return repository.workspace(id: workspaceId)?.tabId(containingPane: remoteTabId) == nil
    }
    #expect(repository.workspace(id: workspaceId)?.pane(containingChat: sessionId)?.id == chatPaneId)
    #expect(repository.workspace(id: workspaceId)?.tabId(containingPane: localNewTab.id) != nil)
  }

  @Test("A pane opened on this device is published once the machine is current; New Tab pages are not")
  func publishesPanesButNotNewTabs() async throws {
    let fake = makeFake()
    let navigation = NavigationFixture()
    let repository = navigation.workspaces
    let controller = makeController(navigation, fake: fake)
    defer { controller.stopEventSync() }
    await controller.refreshNavigationState(for: "local")
    #expect(controller.connection(for: "local").navigationSyncState == .current)

    var workspace = try #require(repository.workspace(id: workspaceId))
    var newTabGroup = PaneGroupState()
    let newTab = newTabGroup.addNewTabPane()
    let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "shell")
    workspace.centerTabs.append(WorkspaceTab(root: .leaf(newTabGroup)))
    workspace.centerTabs.append(
      WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id))))
    repository.save(workspace)
    navigation.workspaceSync.publishPane(newTab, workspaceId: workspaceId)
    navigation.workspaceSync.publishPane(terminal, workspaceId: workspaceId)
    await navigation.store.executor.idle(machineId: "local")

    #expect(fake.paneMutationLog == ["upsert"])
    #expect(fake.workspacePanes?.contains { $0.id == terminal.id.uuidString } == true)
    #expect(fake.workspacePanes?.contains { $0.id == newTab.id.uuidString } == false)
    // The server's event for the new pane lands; the layout keeps both tabs.
    fake.emit(kind: "workspace.pane.created", subjectId: terminal.id.uuidString)
    await awaitObserved {
      _ = navigation.workspaceSync.revision
      return navigation.store.eventCursor(for: "local") == 1
    }
    let synced = try #require(repository.workspace(id: workspaceId))
    #expect(synced.tabId(containingPane: terminal.id) != nil)
    #expect(synced.tabId(containingPane: newTab.id) != nil)
    #expect(navigation.store.pendingIntents.isEmpty)
  }
}
