import Foundation
import Testing

@testable import CodevisorCore

@Suite("Chatless workspace panes")
struct ChatlessWorkspacePaneTests {
  private func workspace(centerTree: SplitNode) -> Workspace {
    Workspace(
      name: "Verification",
      rootDirectory: "/tmp/project",
      serverId: "stage3v",
      projectId: UUID(),
      centerTree: centerTree
    )
  }

  @Test func aCenterGroupWithoutAChatStartsOnTheNewTabPage() {
    let state = PaneGroupState.centerInitialWithoutChat()

    #expect(state.panes.count == 1)
    #expect(state.panes[0].kind == .newTab)
    #expect(state.panes[0].chatSessionId == nil)
    #expect(state.selectedPaneId == state.panes[0].id)
    let space = workspace(centerTree: .leaf(state))
    #expect(space.selectedCenterTab?.root.allGroups.first?.state == state)
    #expect(state.panes[0].terminalKey == state.panes[0].id.uuidString)
  }

  @MainActor
  @Test func workspaceKeyedPanesPersistWithoutASessionKey() {
    let repository = NavigationFixture().workspaces
    var space = workspace(centerTree: .leaf(PaneGroupState.centerInitialWithoutChat()))
    let leafId = space.centerTree.allGroups[0].id
    repository.save(space)

    let bridge = WorkspacePaneGroupRepository(
      workspaceId: space.id, groupId: leafId, repository: repository)

    let loaded = bridge.load(sessionId: nil)
    #expect(loaded?.panes.first?.kind == .newTab)

    var updated = try! #require(loaded)
    updated.addNewTabPane()
    bridge.save(updated, sessionId: nil)

    let reloaded = bridge.load(sessionId: nil)
    #expect(reloaded?.panes.count == 2)
    space = try! #require(repository.workspace(id: space.id))
    #expect(space.centerTree.group(id: leafId)?.panes.count == 2)
  }

  @Test func theSessionKeyedStoreDeclinesAGroupWithoutASession() {
    let legacy = DefaultPaneGroupRepository(store: InMemoryStore())
    var state = PaneGroupState()
    state.addNewTabPane()

    legacy.save(state, sessionId: nil)
    #expect(legacy.load(sessionId: nil) == nil)

    let session = UUID()
    legacy.save(state, sessionId: session)
    #expect(legacy.load(sessionId: session) == state)
    #expect(legacy.load(sessionId: nil) == nil)
  }

  @Test func convertingAPlaceholderWithoutASessionRefusesOnlyTheTerminal() {
    var state = PaneGroupState.centerInitialWithoutChat()
    let paneId = state.panes[0].id

    #expect(state.convertNewTabPane(id: paneId, to: .terminal, sessionId: nil) == nil)
    #expect(state.panes[0].kind == .newTab)

    let converted = state.convertNewTabPane(id: paneId, to: .screenSharing, sessionId: nil)
    #expect(converted?.kind == .screenSharing)
    #expect(converted?.terminalKey == paneId.uuidString)
    #expect(converted?.chatSessionId == nil)
  }

  @Test func aTerminalStillConvertsWhenARealSessionIsPresent() {
    var state = PaneGroupState.centerInitialWithoutChat()
    let paneId = state.panes[0].id
    let session = UUID()

    let converted = state.convertNewTabPane(id: paneId, to: .terminal, sessionId: session)
    #expect(converted?.kind == .terminal)
    #expect(converted?.terminalKey == "\(session.uuidString):\(paneId.uuidString)")
  }

  @Test @MainActor func aServerAuthoredChatlessWorkspaceBecomesSelectableLayout() throws {
    var space = workspace(centerTree: .leaf(PaneGroupState()))
    let record = ServerWorkspacePane(
      id: UUID().uuidString,
      workspaceId: space.id.uuidString,
      providerId: "codevisor",
      paneType: "new-tab",
      title: "New tab",
      createdAt: "2026-09-13T00:00:00.000Z"
    )

    WorkspaceSyncModel.reconcilePanes(in: &space, records: [record], protectedLocalPaneIds: [])

    #expect(space.allPanes.count == 1)
    let pane = try #require(space.allPanes.first)
    #expect(pane.kind == .newTab)
    #expect(pane.id.uuidString != record.id)
    let leafId = try #require(
      space.centerTabs.flatMap { $0.root.allGroups }.first { $0.state.panes.contains { $0.id == pane.id } }?.id)

    let selected = space.selectDestination(.leaf(leafId))
    #expect(selected)

    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .workspace(serverId: space.serverId, id: space.id))
  }

  @Test func aLeafThatGainsAChatRoutesToItInsteadOfTheWorkspace() throws {
    var space = workspace(centerTree: .leaf(PaneGroupState.centerInitialWithoutChat()))
    let leafId = space.centerTree.allGroups[0].id
    let placeholderId = try #require(space.centerTree.group(id: leafId)?.panes.first?.id)

    #expect(
      space.selectionRoute(
        activatedChatSessionId: nil, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .workspace(serverId: space.serverId, id: space.id))

    let chat = UUID()
    var state = try #require(space.centerTree.group(id: leafId))
    let conversion = state.convertNewTabPane(
      id: placeholderId, to: .chat, sessionId: nil, chatSessionId: chat)
    let converted = try #require(conversion)
    space.centerTree = space.centerTree.updatingGroup(id: leafId) { _ in state }

    #expect(converted.id == placeholderId)
    #expect(converted.chatSessionId == chat)
    #expect(space.centerTree.groupId(containingChat: chat) == leafId)

    #expect(
      space.selectionRoute(
        activatedChatSessionId: chat, routingSessionId: nil, selectionAlreadyRoutesWorkspace: false)
        == .session(serverId: space.serverId, id: chat))
  }

  @Test func paneWorkAnchorsOnTheChatWhenThereIsOneAndOnTheWorkspaceOtherwise() {
    let workspaceRoot = "/tmp/project/.worktrees/verification"
    let projectRoot = "/tmp/project"

    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .session(cwd: "/tmp/project/.worktrees/chat"),
        workspaceRootDirectory: workspaceRoot, projectFolderPath: projectRoot)
        == "/tmp/project/.worktrees/chat")
    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .session(cwd: nil), workspaceRootDirectory: workspaceRoot,
        projectFolderPath: projectRoot) == projectRoot)

    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .workspace, workspaceRootDirectory: workspaceRoot, projectFolderPath: projectRoot)
        == workspaceRoot)
    #expect(
      PaneWorkingDirectory.resolve(
        anchor: .workspace, workspaceRootDirectory: nil, projectFolderPath: projectRoot)
        == projectRoot)
  }
}
